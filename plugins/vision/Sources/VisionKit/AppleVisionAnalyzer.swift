import CoreGraphics
import CoreVideo
import Foundation
import VCGeometry
import VCKStubs
import Vision

/// The production `VisionAnalyzing`: Apple's Vision framework, four request
/// objects, constructed lazily and released the moment nothing needs them.
///
/// This is the ONLY place in the plugin where Vision's coordinate convention
/// (normalized, origin bottom-left, y UP) exists. Every point, rect and mask
/// column this type emits has already gone through `ViewerSpaceMapping` into
/// viewer space (origin top-left, y DOWN, mirrored as the connection reported)
/// — nothing downstream ever sees a Vision-space coordinate.
///
/// `@unchecked Sendable` under the confinement contract on `VisionAnalyzing`:
/// the `VNRequest`s below are mutable reference types with no internal
/// synchronization, and the argument for safety is that only
/// `CameraSession.frameQueue` — one serial queue — ever touches them. Nothing
/// here claims `VNRequest` is thread-safe; it claims this specific usage is
/// single-threaded. This mirrors the `nonisolated(unsafe) let extractor`
/// argument the detector this replaces made for the identical reason.
public final class AppleVisionAnalyzer: VisionAnalyzing, @unchecked Sendable {
    /// Fixed downsample grid for the segmentation mask — coarse enough to
    /// sample and pack per frame, fine enough for a head silhouette. 64x48
    /// packs to 384 bytes, which is why the mask is an ordinary bus payload
    /// rather than something needing a side channel.
    public static let maskCols = 64
    public static let maskRows = 48

    /// Minimum per-joint confidence for a hand fingertip to be trusted. Kept
    /// as the shipped detector's value: an occluded fingertip still has
    /// coordinates and they are fiction. The threshold is not applied here —
    /// every joint is published, per the wire contract's "never short, never
    /// sparse" rule — it rides along in `Hand.joint_confidence` so consumers
    /// can apply their own.
    public static let fingertipConfidenceFloor: Float = 0.3

    // Lazily constructed, released to `nil` the moment `setActiveModels` stops
    // naming their topic.
    private var faceRequest: VNDetectFaceLandmarksRequest?
    private var handRequest: VNDetectHumanHandPoseRequest?
    private var bodyRequest: VNDetectHumanBodyPoseRequest?
    private var segmentationRequest: VNGeneratePersonSegmentationRequest?

    public init() {}

    public var activeModels: Set<VisionTopic> {
        var out: Set<VisionTopic> = []
        if faceRequest != nil { out.insert(.face) }
        if handRequest != nil { out.insert(.hands) }
        if bodyRequest != nil { out.insert(.bodyPose) }
        if segmentationRequest != nil { out.insert(.segmentation) }
        return out
    }

    @discardableResult
    public func setActiveModels(_ topics: Set<VisionTopic>) -> VisionModelChange {
        let wanted = topics.intersection(VisionModelTopics)
        let have = activeModels
        let change = VisionModelChange(constructed: wanted.subtracting(have),
                                       released: have.subtracting(wanted))
        guard !change.isEmpty else { return change }

        for topic in change.constructed {
            switch topic {
            case .face:
                let request = VNDetectFaceLandmarksRequest()
                // Pin the constellation explicitly. The wire contract
                // documents `points` as the 76-point `allPoints` order, and
                // the default has changed across OS releases — leaving it
                // implicit is how a consumer's hard-coded region offset
                // silently starts indexing a different landmark.
                request.constellation = .constellation76Points
                faceRequest = request
                loggedFaceLayout = false
            case .hands:
                let request = VNDetectHumanHandPoseRequest()
                request.maximumHandCount = 2
                handRequest = request
            case .bodyPose:
                bodyRequest = VNDetectHumanBodyPoseRequest()
            case .segmentation:
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = .fast    // real-time
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                segmentationRequest = request
            case .signals:
                break                            // free — no model
            }
        }

        for topic in change.released {
            switch topic {
            case .face: faceRequest = nil
            case .hands: handRequest = nil
            case .bodyPose: bodyRequest = nil
            case .segmentation: segmentationRequest = nil
            case .signals: break
            }
        }

        if !change.constructed.isEmpty {
            visionLog("constructed models [\(change.constructed.sorted().map(\.name).joined(separator: ","))]")
        }
        if !change.released.isEmpty {
            visionLog("released models [\(change.released.sorted().map(\.name).joined(separator: ","))]")
        }
        return change
    }

    public func analyze(_ buffer: CVPixelBuffer,
                        run: Set<VisionTopic>,
                        header: VCTHeader,
                        mirrored: Bool) -> VisionFrameBundle {
        var bundle = VisionFrameBundle(header: header)
        let due = run.intersection(activeModels)
        guard !due.isEmpty else { return bundle }

        var requests: [VNRequest] = []
        if due.contains(.face), let r = faceRequest { requests.append(r) }
        if due.contains(.hands), let r = handRequest { requests.append(r) }
        if due.contains(.bodyPose), let r = bodyRequest { requests.append(r) }
        if due.contains(.segmentation), let r = segmentationRequest { requests.append(r) }
        guard !requests.isEmpty else { return bundle }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
        do {
            try handler.perform(requests)
        } catch {
            // Not fatal and not a reason to publish anything: a failed
            // `perform` is "we do not know", which is exactly the absent case.
            // Publishing empty frames here would tell consumers "the model ran
            // and saw nothing", which is a different and false statement.
            visionLog("Vision perform failed: \(error)")
            return bundle
        }

        if due.contains(.face) {
            let (frame, layout) = faceFrame(header: header, mirrored: mirrored)
            bundle.face = frame
            bundle.faceLayout = layout
        }
        if due.contains(.hands) { bundle.hands = handsFrame(header: header, mirrored: mirrored) }
        if due.contains(.bodyPose) { bundle.body = bodyFrame(header: header, mirrored: mirrored) }
        if due.contains(.segmentation) {
            bundle.segmentation = segmentationFrame(header: header, mirrored: mirrored)
        }
        return bundle
    }

    // MARK: - Face

    private func faceFrame(header: VCTHeader, mirrored: Bool) -> (VCTFaceFrame, FaceLandmarkLayout?) {
        var frame = VCTFaceFrame()
        frame.header = header
        // No observation is the valid "the model ran and saw no face" message:
        // an empty `points` with a zero `bounds`.
        guard let face = faceRequest?.results?.max(by: { $0.confidence < $1.confidence }) else {
            return (frame, nil)
        }
        frame.bounds = ViewerSpaceMapping.protoRect(face.boundingBox, mirrored: mirrored)
        frame.confidence = face.confidence
        guard let landmarks = face.landmarks, let all = landmarks.allPoints else {
            return (frame, nil)
        }
        // `pointsInImage(imageSize: 1x1)` yields whole-image normalized
        // Vision-space coordinates; the region's own `normalizedPoints`
        // are relative to the bounding box and would land the whole
        // constellation inside a tiny square in the corner.
        frame.points = all.pointsInImage(imageSize: CGSize(width: 1, height: 1))
            .map { ViewerSpaceMapping.protoPoint($0, mirrored: mirrored) }
        return (frame, layout(of: landmarks, publishedPointCount: frame.points.count))
    }

    /// The per-region point counts of the constellation this frame actually
    /// carried, in `FaceRegion.allCases` order — which the wire contract pins
    /// as the order `allPoints` concatenates.
    ///
    /// **Measured, never assumed.** Apple documents neither the counts nor,
    /// strictly, that `allPoints` is that concatenation, and both differ
    /// between the 65- and 76-point constellations. So the sum is checked
    /// against the array that was actually published: a disagreement means the
    /// concatenation assumption is wrong on this OS, and the honest answer is
    /// `nil` (every face-derived signal absent) rather than an offset table
    /// that reports an eyebrow as an eye. The mismatch is logged once, with
    /// both numbers, because it is the one thing a person running this against
    /// a real camera can check and nobody can check from source.
    private func layout(of landmarks: VNFaceLandmarks2D,
                        publishedPointCount: Int) -> FaceLandmarkLayout? {
        let regions: [VNFaceLandmarkRegion2D?] = [
            landmarks.faceContour,
            landmarks.leftEye, landmarks.rightEye,
            landmarks.leftEyebrow, landmarks.rightEyebrow,
            landmarks.nose, landmarks.noseCrest, landmarks.medianLine,
            landmarks.outerLips, landmarks.innerLips,
            landmarks.leftPupil, landmarks.rightPupil,
        ]
        let counts = regions.map { $0?.pointCount ?? 0 }
        guard let layout = FaceLandmarkLayout(pointCounts: counts),
              layout.totalPointCount == publishedPointCount else {
            logFaceLayoutOnce("face regions sum to \(counts.reduce(0, +)) but allPoints "
                              + "published \(publishedPointCount) — signals derived from the "
                              + "face constellation stay absent (counts=\(counts))")
            return nil
        }
        logFaceLayoutOnce("face constellation layout measured: \(counts) "
                          + "(total \(layout.totalPointCount)); regions in "
                          + "FaceRegion.allCases order")
        return layout
    }

    /// The layout is stable for the life of a request object, so logging it
    /// per frame would bury everything else at 30 Hz. Reset when the face
    /// model is reconstructed, so a constellation that changes across a
    /// release is reported again rather than silently inherited.
    private var loggedFaceLayout = false

    private func logFaceLayoutOnce(_ message: String) {
        guard !loggedFaceLayout else { return }
        loggedFaceLayout = true
        visionLog(message)
    }

    // MARK: - Hands

    /// The normative 21-joint order the wire contract declares. Index 8 is
    /// always the index fingertip, for every publisher and every consumer.
    static let handJointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private func handsFrame(header: VCTHeader, mirrored: Bool) -> VCTHandsFrame {
        var frame = VCTHandsFrame()
        frame.header = header
        let observations = handRequest?.results ?? []
        frame.hands = observations
            .sorted { $0.confidence > $1.confidence }    // descending, per the contract
            .prefix(2)
            .map { hand(from: $0, mirrored: mirrored) }
        return frame
    }

    private func hand(from observation: VNHumanHandPoseObservation, mirrored: Bool) -> VCTHand {
        var hand = VCTHand()
        hand.confidence = observation.confidence
        switch observation.chirality {
        case .left: hand.handedness = .left
        case .right: hand.handedness = .right
        default: hand.handedness = .unspecified
        }
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        // Never short and never sparse: a joint the model could not locate is
        // still published, at its last estimate, with a low entry in
        // `jointConfidence`. A missing key falls back to (0,0)/0 — coordinates
        // a consumer is told to distrust rather than an index shift that
        // silently turns the index fingertip into a knuckle.
        for name in Self.handJointOrder {
            let point = recognized[name]
            hand.joints.append(ViewerSpaceMapping.protoPoint(
                point.map { CGPoint(x: $0.location.x, y: $0.location.y) } ?? .zero,
                mirrored: mirrored
            ))
            hand.jointConfidence.append(point?.confidence ?? 0)
        }
        return hand
    }

    // MARK: - Body pose

    /// The normative 19-joint order the wire contract declares. "left" and
    /// "right" are the SUBJECT's, which in viewer space appear on the
    /// mirrored side of the image from where a naive read would put them.
    static let bodyJointOrder: [VNHumanBodyPoseObservation.JointName] = [
        .nose,
        .leftEye, .rightEye,
        .leftEar, .rightEar,
        .neck,
        .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow,
        .leftWrist, .rightWrist,
        .root,
        .leftHip, .rightHip,
        .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
    ]

    private func bodyFrame(header: VCTHeader, mirrored: Bool) -> VCTBodyPoseFrame {
        var frame = VCTBodyPoseFrame()
        frame.header = header
        // Empty `joints` is the valid "no body detected" message.
        guard let body = bodyRequest?.results?.max(by: { $0.confidence < $1.confidence }) else {
            return frame
        }
        let recognized = (try? body.recognizedPoints(.all)) ?? [:]
        frame.joints = Self.bodyJointOrder.map { name in
            let point = recognized[name]
            var joint = VCTJoint()
            joint.point = ViewerSpaceMapping.protoPoint(
                point.map { CGPoint(x: $0.location.x, y: $0.location.y) } ?? .zero,
                mirrored: mirrored
            )
            joint.confidence = point?.confidence ?? 0
            return joint
        }
        return frame
    }

    // MARK: - Segmentation

    private func segmentationFrame(header: VCTHeader, mirrored: Bool) -> VCTSegmentationFrame {
        var frame = VCTSegmentationFrame()
        frame.header = header
        // `w == 0 && h == 0` with an empty mask is the valid "no person
        // segmented" message.
        guard let observation = segmentationRequest?.results?.first else { return frame }
        let mask = observation.pixelBuffer

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return frame }

        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard maskWidth > 0, maskHeight > 0 else { return frame }

        let cols = Self.maskCols, rows = Self.maskRows
        let buffer = base.assumingMemoryBound(to: UInt8.self)
        var cells = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            // The buffer is sampled top-down and stored row-major with row 0 =
            // top. Viewer space is also y-down, so rows need no flip.
            let my = min(maskHeight - 1, Int((Double(r) + 0.5) / Double(rows) * Double(maskHeight)))
            for c in 0..<cols {
                // Columns DO need the flip: the buffer's column order matches
                // the source frame, so an unmirrored source must be reversed
                // exactly as `ViewerSpaceMapping.point` reverses x — or the
                // mask ends up mirrored relative to every landmark published
                // alongside it, from the same frame, with the same `seq`.
                let sourceCol = ViewerSpaceMapping.sourceColumn(forViewerColumn: c,
                                                                cols: cols,
                                                                mirrored: mirrored)
                let mx = min(maskWidth - 1,
                             Int((Double(sourceCol) + 0.5) / Double(cols) * Double(maskWidth)))
                cells[r * cols + c] = buffer[my * bytesPerRow + mx] > 127
            }
        }

        frame.w = UInt32(cols)
        frame.h = UInt32(rows)
        frame.mask = Self.packBits(cells)
        return frame
    }

    /// Packs a row-major boolean grid into the wire's MSB-first bitmask:
    /// bit `index = row * w + col` lives at `mask[index / 8] >> (7 - index % 8)`.
    /// Trailing bits of the final byte are zero.
    ///
    /// `static` and pure so the packing rule is assertable against the
    /// contract's own formula without a camera — a bit order silently
    /// disagreeing with the proto comment would otherwise only show up as a
    /// consumer drawing a scrambled silhouette.
    static func packBits(_ cells: [Bool]) -> Data {
        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (index, on) in cells.enumerated() where on {
            bytes[index / 8] |= UInt8(0x80) >> UInt8(index % 8)
        }
        return Data(bytes)
    }
}
