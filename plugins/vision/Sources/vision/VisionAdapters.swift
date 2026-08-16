import Foundation
import VCKStubs
import VCPluginSDK
import VisionAPI
import VisionKit

// The seam between the two halves of this plugin.
//
// `VisionAPI` codes against four narrow protocols it declares itself
// (`Sources/VisionAPI/VisionSurface.swift`) rather than importing `VisionKit`.
// That inversion is deliberate and worth keeping: it is what lets every
// `/api/*` route be tested with no camera, no AVFoundation and no bus — a test
// process carries no `NSCameraUsageDescription`, so a test that reached a real
// capture device would face a TCC prompt and hang — and it is what keeps the
// BUS contract (`VCT…`, §4) and the HTTP contract (the JSON a TUI parses) from
// silently becoming one contract that a proto field rename can break.
//
// The cost of the inversion is exactly this file: somebody has to conform the
// real types. The composition root is where that belongs, because it is the
// only place that already depends on both.
//
// Everything here is a projection. No decision is made in this file — if a
// readout looks wrong, the fact is wrong upstream in `VisionProvider`, not
// here.

// MARK: - State

struct ProviderStateSource: VisionStateSource {
    let provider: VisionProvider

    func visionState() async -> VisionState {
        let snapshot = await provider.snapshot()
        // One wall-clock reading for the whole projection: `expiresIn` is a
        // duration from the moment the snapshot was taken, and sampling `now`
        // once per requester would spread a single instant across several.
        let now = Date()
        return VisionState(
            camera: VisionCameraState(
                selectedDeviceID: snapshot.device?.id,
                selectedDeviceName: snapshot.device?.name,
                // The session, not the request union. This is what the LED
                // follows, so it is what "the camera is on" must be keyed to.
                isOpen: snapshot.capturing,
                permission: permission(snapshot.permission),
                frameWidth: snapshot.geometry.width,
                frameHeight: snapshot.geometry.height,
                isMirrored: snapshot.geometry.mirrored
            ),
            // Every topic, running or not: "hands is not running" is what a
            // reader of the privacy readout came to find out, and a topic that
            // vanishes from the list reads as one that was never implemented.
            topics: snapshot.topics.map {
                VisionTopicStatus(topic: $0.topic,
                                  isRunning: $0.running,
                                  fps: $0.fps,
                                  subscribers: $0.subscribers,
                                  requesters: $0.requesters)
            },
            requests: snapshot.requesters.map {
                VisionActiveRequest(requester: $0.requester,
                                    topics: $0.topics,
                                    fps: $0.fps,
                                    expiresAt: now.addingTimeInterval($0.expiresIn))
            }
        )
    }

    /// The one lossy step in the whole adapter, and it loses in the safe
    /// direction.
    ///
    /// `CameraStartResult` cannot distinguish `restricted` (MDM or parental
    /// controls forbid the camera, and the user cannot change it) from
    /// `denied` — `AVCaptureDevice.requestAccess` reports both as "no". So
    /// `.restricted` is never claimed here. Claiming it wrongly would tell a
    /// user their admin blocked the camera when in fact they clicked Deny and
    /// could fix it in one visit to System Settings.
    private func permission(_ value: VisionPermission) -> VisionCameraPermission {
        switch value {
        case .unknown: return .notDetermined
        case .granted: return .authorized
        case .denied: return .denied
        case .noDevice: return .noDevice
        }
    }
}

// MARK: - Camera selection

struct ProviderCameraControl: VisionCameraControl {
    let provider: VisionProvider

    func availableCameras() async -> [VisionCameraDevice] {
        provider.cameras().map { VisionCameraDevice(id: $0.id, name: $0.name) }
    }

    func selectCamera(id: String) async -> VisionCameraSelectionOutcome {
        // `selectCamera` returns false for exactly one reason — no attached
        // device has that id — which the HTTP layer answers with a 404. A
        // capture failure after a valid selection is not an error here: the
        // provider degrades in place and retries on its own backoff, and
        // `/api/state` reports the permission that resulted. Reporting it as
        // `.failed` would turn a recoverable "the user has not granted
        // access yet" into a 500.
        await provider.selectCamera(id: id) ? .selected : .unknownDevice
    }
}

// MARK: - Preview

/// A wrapper rather than a retroactive `extension PreviewStream:
/// VisionPreviewSink` — conforming a type from one imported module to a
/// protocol from another is exactly the conformance Swift 6 asks you to mark
/// `@retroactive`, because whichever module later declares it for real would
/// then collide. `PreviewStream` already has the right shape; it just should
/// not be the thing that claims it.
struct ProviderPreviewSink: VisionPreviewSink {
    let preview: PreviewStream

    func attach(_ writer: any VCResponseWriter) async {
        await preview.attach(writer)
    }
}

// MARK: - Overlay

struct ProviderOverlaySource: VisionOverlaySource {
    let provider: VisionProvider

    func overlayFrames() async -> AsyncStream<VisionOverlayFrame> {
        let source = provider.frames()
        let (stream, continuation) = AsyncStream<VisionOverlayFrame>.makeStream(
            of: VisionOverlayFrame.self,
            // Same reasoning as the upstream stream's own bound: an overlay
            // wants the freshest frame and has no use for a backlog. A browser
            // that fell behind should skip, not replay.
            bufferingPolicy: .bufferingNewest(2)
        )
        let pump = Task {
            for await bundle in source {
                continuation.yield(overlayFrame(bundle))
            }
            // The provider finished the upstream stream — shutdown, per
            // `FrameProcessor.finishFrameStreams` — so the SSE handler's
            // `for await` must end rather than hang through it.
            continuation.finish()
        }
        // The ONLY signal that a browser went away: the handler stops
        // iterating, this stream deinits, and the pump (and with it the
        // provider's per-viewer bookkeeping upstream) is torn down. Without
        // this, a closed tab would leave a frame sink registered forever and
        // "produce nothing for nobody" would quietly stop being true.
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }
}

/// Projects one analysed frame onto what a 2D canvas can draw.
///
/// Deliberately not a re-export of the bus payloads: consumers of the *bus*
/// get the full proto messages, consumers of `/api/events` get the preview's
/// geometry and nothing else. Coordinates arrive already in viewer space and
/// already mirrored, so nothing here transforms anything.
func overlayFrame(_ bundle: VisionFrameBundle) -> VisionOverlayFrame {
    let header = bundle.header
    return VisionOverlayFrame(
        seq: header.seq,
        ts: header.hasTs ? header.ts.date : Date(),
        imageWidth: Int(header.frame.w),
        imageHeight: Int(header.frame.h),
        face: bundle.face.flatMap(overlayFace),
        hands: bundle.hands?.hands.map(overlayHand) ?? [],
        body: bundle.body.map(overlayJoints) ?? [],
        segmentation: bundle.segmentation.flatMap(overlayMask)
    )
}

/// A face frame with no points is the valid "the model ran and saw nobody"
/// message, and it must draw nothing rather than a zero-sized box at the
/// origin — which is what a `Rect` of all zeros would render as.
private func overlayFace(_ face: VCTFaceFrame) -> VisionOverlayFrame.Face? {
    guard !face.points.isEmpty else { return nil }
    return VisionOverlayFrame.Face(
        bounds: VisionOverlayFrame.Rect(x: face.bounds.x,
                                        y: face.bounds.y,
                                        width: face.bounds.w,
                                        height: face.bounds.h),
        points: face.points.map { VisionOverlayFrame.Point(x: $0.x, y: $0.y) },
        confidence: face.confidence
    )
}

private func overlayHand(_ hand: VCTHand) -> VisionOverlayFrame.Hand {
    VisionOverlayFrame.Hand(
        chirality: {
            switch hand.handedness {
            case .left: return "left"
            case .right: return "right"
            // `.unspecified` is Vision declining to choose, which is a real
            // expected value and not a wire error. `UNRECOGNIZED` is a
            // provider newer than these stubs; both print as "unknown".
            default: return "unknown"
            }
        }(),
        points: hand.joints.map { VisionOverlayFrame.Point(x: $0.x, y: $0.y) },
        confidence: hand.confidence
    )
}

/// Joint names come from `BodyJoint`'s declaration order, which the wire
/// contract pins as the order `BodyPoseFrame.joints` is published in. A frame
/// carrying a different count than the normative 19 is drawn as far as the
/// names go and no further, rather than shifting every label by one.
private func overlayJoints(_ body: VCTBodyPoseFrame) -> [VisionOverlayFrame.Joint] {
    body.joints.enumerated().map { index, joint in
        VisionOverlayFrame.Joint(
            name: bodyJointNames.indices.contains(index) ? bodyJointNames[index] : "joint\(index)",
            point: VisionOverlayFrame.Point(x: joint.point.x, y: joint.point.y),
            confidence: joint.confidence
        )
    }
}

/// The normative 19-joint order, spelled as the labels the overlay prints.
/// "left" and "right" are the SUBJECT's — in a mirrored selfie preview the
/// subject's left appears on the viewer's left.
private let bodyJointNames = [
    "nose",
    "leftEye", "rightEye",
    "leftEar", "rightEar",
    "neck",
    "leftShoulder", "rightShoulder",
    "leftElbow", "rightElbow",
    "leftWrist", "rightWrist",
    "root",
    "leftHip", "rightHip",
    "leftKnee", "rightKnee",
    "leftAnkle", "rightAnkle",
]

/// Passed through byte for byte, so there is one packing in this system and
/// not two that can disagree: row-major, MSB first, bit `i == row * cols + col`
/// living in `packed[i / 8]` at position `7 - (i % 8)`. `VisionWire` base64s
/// exactly these bytes and `ui/index.html` decodes exactly that formula.
private func overlayMask(_ frame: VCTSegmentationFrame) -> VisionOverlayFrame.Mask? {
    let cols = Int(frame.w)
    let rows = Int(frame.h)
    guard cols > 0, rows > 0, !frame.mask.isEmpty else { return nil }
    return VisionOverlayFrame.Mask(cols: cols, rows: rows, packed: [UInt8](frame.mask))
}
