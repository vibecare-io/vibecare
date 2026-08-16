import Foundation
import VCPluginSDK

// Everything `VisionAPI` needs from the capture side, and nothing more.
//
// These four protocols are deliberately narrow and live HERE rather than in
// `VisionKit`: this target must be drivable with no camera, no AVFoundation
// and no bus, or none of `/api/*` could be tested inside `swift test` (which
// carries no `NSCameraUsageDescription`, and whose process would face a real
// TCC prompt the moment it touched a capture device). Every fixture in
// `Tests/VisionAPITests` is a plain actor conforming to these.
//
// They are also why `VisionAPI` does not depend on `VCKStubs`: the generated
// `VCTFaceFrame`/`VCTHandsFrame`/… types are the BUS contract (§4), which is a
// different contract from the HTTP one this file serves. `VisionKit` owns the
// translation between them. Keeping the two apart means a proto field
// rename cannot silently change the JSON a TUI or a script is parsing.

// MARK: - State

/// The whole "what is this plugin doing right now" readout, as facts.
///
/// Deliberately facts and not sentences: the derived readout — the running
/// list, the `subscriber with no request` warnings (§5.3) and the one-line
/// privacy summary — are computed from these by `VisionReadout.swift`, so
/// they are pure functions with tests rather than something the capture actor
/// has to remember to keep current.
public protocol VisionStateSource: Sendable {
    func visionState() async -> VisionState
}

public struct VisionState: Sendable {
    public var camera: VisionCameraState
    /// One entry per topic vision can publish, running or not. Including the
    /// idle ones is not padding: "hands is NOT running" is exactly what a
    /// user checking the privacy readout came to find out, and a topic that
    /// vanishes from the list is indistinguishable from a topic that was
    /// never implemented.
    public var topics: [VisionTopicStatus]
    /// The live `vision.request.v1` union (§5.3), latest-wins per requester,
    /// already filtered to unexpired requests by whoever supplies it.
    public var requests: [VisionActiveRequest]

    public init(
        camera: VisionCameraState,
        topics: [VisionTopicStatus],
        requests: [VisionActiveRequest] = []
    ) {
        self.camera = camera
        self.topics = topics
        self.requests = requests
    }
}

public struct VisionCameraState: Sendable {
    /// `nil` before anything has been selected, which is not the same as
    /// "no camera exists" — that is `permission == .noDevice`.
    public var selectedDeviceID: String?
    public var selectedDeviceName: String?
    /// Whether the `AVCaptureSession` is actually running. This — not the
    /// request union — is what the LED follows, so it is what the UI's
    /// "camera is on" claim must be keyed to.
    public var isOpen: Bool
    public var permission: VisionCameraPermission
    /// Source pixel dimensions of the frames being delivered, `0` while
    /// closed. The overlay's aspect-fill mapping needs these, and a UI that
    /// guessed 16:9 would drift the overlay off the face on any other ratio.
    public var frameWidth: Int
    public var frameHeight: Int
    /// Read per frame from `connection.isVideoMirrored`, never inferred —
    /// the built-in Mac camera reports `position = .unspecified`, so nothing
    /// arrives pre-mirrored (§4.3).
    public var isMirrored: Bool

    public init(
        selectedDeviceID: String? = nil,
        selectedDeviceName: String? = nil,
        isOpen: Bool = false,
        permission: VisionCameraPermission = .notDetermined,
        frameWidth: Int = 0,
        frameHeight: Int = 0,
        isMirrored: Bool = false
    ) {
        self.selectedDeviceID = selectedDeviceID
        self.selectedDeviceName = selectedDeviceName
        self.isOpen = isOpen
        self.permission = permission
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.isMirrored = isMirrored
    }
}

/// Mirrors `AVAuthorizationStatus` plus the one case it cannot express — a
/// Mac with the permission granted and no camera attached at all, which
/// presents to a user exactly like a broken plugin unless it is named.
public enum VisionCameraPermission: String, Sendable, Codable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case noDevice
}

/// One publishable topic and the two independent facts that decide whether
/// its model runs (§5): `subscribers` is the kernel's demand refcount (the
/// privacy FLOOR — zero means the model may not run at all, ever), and
/// `requesters` is who named the topic in a live `vision.request.v1` (the
/// INTENT). `isRunning` is the provider's own answer, not a re-derivation:
/// only the capture side knows whether it has actually constructed the
/// `VNRequest` yet.
public struct VisionTopicStatus: Sendable {
    public var topic: String
    public var isRunning: Bool
    /// Effective rate — `max()` across requesters, capped at 30 (§6) — and
    /// `0` when the model is not running.
    public var fps: Int
    public var subscribers: Int
    /// Plugin ids from `Request.requester`. **Self-asserted and not
    /// authenticated** (§5.3): `BusEvent` carries no publisher id, so this
    /// is a claim, not a proof. It is still the most useful thing the
    /// privacy readout can say, and the demand floor is what actually gates
    /// the camera.
    public var requesters: [String]

    public init(topic: String, isRunning: Bool, fps: Int = 0, subscribers: Int = 0, requesters: [String] = []) {
        self.topic = topic
        self.isRunning = isRunning
        self.fps = fps
        self.subscribers = subscribers
        self.requesters = requesters
    }
}

public struct VisionActiveRequest: Sendable {
    public var requester: String
    public var topics: [String]
    public var fps: Int
    /// When this request lapses unless re-asserted. Consumers heartbeat well
    /// inside the TTL (10 s against 30 s), so a value close to `now` in the
    /// readout means a consumer has stopped heartbeating — which is worth
    /// being able to see.
    public var expiresAt: Date

    public init(requester: String, topics: [String], fps: Int, expiresAt: Date) {
        self.requester = requester
        self.topics = topics
        self.fps = fps
        self.expiresAt = expiresAt
    }
}

// MARK: - Camera selection

public struct VisionCameraDevice: Sendable, Equatable {
    /// `AVCaptureDevice.uniqueID`. Stable across replugs for built-in
    /// cameras, which is what makes it safe to persist a selection.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The three outcomes the HTTP layer has to tell apart, because they are
/// three different status codes. `unknownDevice` is a caller's mistake (404,
/// with a message); `failed` is ours (logged server-side, generic 500) — the
/// same error discipline `plugins/todo/main.go` and vibecheck's `API.swift`
/// use, and for the same reason: a capture error's text can name a device
/// path that is not the client's to see.
public enum VisionCameraSelectionOutcome: Sendable, Equatable {
    case selected
    case unknownDevice
    case failed(String)
}

public protocol VisionCameraControl: Sendable {
    func availableCameras() async -> [VisionCameraDevice]
    func selectCamera(id: String) async -> VisionCameraSelectionOutcome
}

// MARK: - Preview

/// `/preview.mjpeg` attaches and returns; the sink owns the writer from then
/// on and drives it from the camera's own frame callback. Same shape, same
/// reasoning, as vibecheck's `PreviewStream.attach` — it is what lets several
/// viewers share one upstream camera instead of each blocking a request
/// `Task` forever.
///
/// The implementation MUST idle for free with nothing attached: JPEG encoding
/// for nobody is the second largest avoidable cost after inference (§6).
/// Nothing in this target can enforce that, which is why it is written down
/// here as a requirement on the conformer rather than assumed.
public protocol VisionPreviewSink: Sendable {
    func attach(_ writer: any VCResponseWriter) async
}

// MARK: - Overlay

/// The live-tier stream the `<canvas>` overlay draws. One stream per attached
/// browser; the provider learns a browser went away from the stream's
/// `onTermination`, which is the only signal `/api/events` gives it — the
/// handler simply stops iterating when its write fails.
///
/// Same "produce nothing for nobody" requirement as `VisionPreviewSink`:
/// with no stream outstanding, nothing should be built at all.
public protocol VisionOverlaySource: Sendable {
    func overlayFrames() async -> AsyncStream<VisionOverlayFrame>
}

/// One frame's worth of drawable geometry, joined across tiers by
/// `Header.seq` (§4) before it gets here.
///
/// This is an OVERLAY shape, not a re-export of the bus payloads: it carries
/// only what a 2D canvas can draw, in viewer space, already mirrored.
/// Consumers of the *bus* get the full proto messages; consumers of this
/// stream get what the preview needs and nothing else.
public struct VisionOverlayFrame: Sendable {
    public struct Point: Sendable, Equatable {
        public var x: Float
        public var y: Float
        public init(x: Float, y: Float) {
            self.x = x
            self.y = y
        }
    }

    public struct Rect: Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var width: Float
        public var height: Float
        public init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Face: Sendable {
        public var bounds: Rect
        public var points: [Point]
        public var confidence: Float
        public init(bounds: Rect, points: [Point], confidence: Float) {
            self.bounds = bounds
            self.points = points
            self.confidence = confidence
        }
    }

    public struct Hand: Sendable {
        /// `"left"`, `"right"` or `"unknown"` — a string rather than an enum
        /// because it is a label the overlay prints, and a provider that
        /// grows a fourth answer should not need this target recompiled.
        public var chirality: String
        public var points: [Point]
        public var confidence: Float
        public init(chirality: String, points: [Point], confidence: Float) {
            self.chirality = chirality
            self.points = points
            self.confidence = confidence
        }
    }

    public struct Joint: Sendable {
        public var name: String
        public var point: Point
        public var confidence: Float
        public init(name: String, point: Point, confidence: Float) {
            self.name = name
            self.point = point
            self.confidence = confidence
        }
    }

    /// The person-segmentation bitmask, carried in EXACTLY the packing
    /// `proto/topics/v1/vision.proto` defines — row-major, MSB first, bit
    /// `i == row * cols + col` living in `packed[i / 8]` at position
    /// `7 - (i % 8)`. Passed straight through to base64 on the wire, so
    /// there is one packing in the system and not two that can disagree.
    public struct Mask: Sendable {
        public var cols: Int
        public var rows: Int
        public var packed: [UInt8]
        public init(cols: Int, rows: Int, packed: [UInt8]) {
            self.cols = cols
            self.rows = rows
            self.packed = packed
        }
    }

    /// Shared by every tier derived from one camera frame (§4). The overlay
    /// draws a frame as a unit, so a mismatched `seq` never reaches it.
    public var seq: UInt64
    public var ts: Date
    /// Source pixel dimensions — the aspect-fill mapping's `fa` comes from
    /// these and nothing else.
    public var imageWidth: Int
    public var imageHeight: Int
    public var face: Face?
    public var hands: [Hand]
    public var body: [Joint]
    public var segmentation: Mask?

    public init(
        seq: UInt64,
        ts: Date,
        imageWidth: Int,
        imageHeight: Int,
        face: Face? = nil,
        hands: [Hand] = [],
        body: [Joint] = [],
        segmentation: Mask? = nil
    ) {
        self.seq = seq
        self.ts = ts
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.face = face
        self.hands = hands
        self.body = body
        self.segmentation = segmentation
    }
}
