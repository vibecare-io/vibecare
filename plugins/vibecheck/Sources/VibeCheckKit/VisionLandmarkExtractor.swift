import Vision
import CoreVideo
import Foundation

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — see the identical
/// rule and reasoning in `CameraSession.swift` / `VCPluginSDK/VCLog.swift`.
private func visionLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// Runs Vision hand-pose + face-landmark requests on a pixel buffer and
/// reduces the results to the few points BFRB detection needs.
/// Impure (talks to Vision); the pure geometry lives in `BFRBDetector`.
///
/// This is the ONLY place in the plugin where Vision's coordinate
/// convention (normalized, origin bottom-left, y UP) exists. Every point and
/// rect this type emits has already been converted to viewer space (origin
/// top-left, y DOWN) via `normalize` below — nothing downstream ever sees a
/// Vision-space coordinate.
public struct VisionLandmarkExtractor {
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast            // real-time; user can bump to .balanced later
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    /// Fixed downsample resolution for the hair-mask grid — coarse enough to
    /// be cheap to sample/draw per frame, fine enough for a head silhouette.
    private static let maskCols = 64
    private static let maskRows = 48

    public init() {}

    /// - Parameters:
    ///   - mirrored: whether the SOURCE connection already mirrored x (see
    ///     `CameraFrameReceiver.didOutput`). Threaded into every point/rect
    ///     conversion this call performs.
    ///   - seq: monotonic frame sequence number, passed through unchanged.
    ///   - ts: **capture** time, sampled by the caller before this function
    ///     ran — not sampled in here. Sampling after Vision has run would
    ///     fold inference latency into the timestamp, which the downstream
    ///     conformance-window budget cannot absorb.
    public func analyze(_ pixelBuffer: CVPixelBuffer, mirrored: Bool, seq: UInt64, ts: Date) -> LandmarkFrame {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([handRequest, faceRequest, segmentationRequest])
        } catch {
            visionLog("Vision perform failed: \(error)")
            return LandmarkFrame(hand: nil, face: nil, imageSize: imageSize, ts: ts, seq: seq, mirrored: mirrored)
        }
        return LandmarkFrame(hand: extractHand(mirrored: mirrored),
                              face: extractFace(mirrored: mirrored),
                              imageSize: imageSize,
                              hairMask: extractHairMask(mirrored: mirrored),
                              ts: ts,
                              seq: seq,
                              mirrored: mirrored)
    }

    // MARK: - Coordinate normalization
    //
    // Deliberately NOT `private`, unlike the rest of this type: these two
    // functions are pure (no Vision, no camera) and are exactly where the
    // real risk in this file lives, so they need to be reachable from
    // `VibeCheckKitTests` via `@testable import`. Everything else here needs
    // real hardware to exercise and is verified manually instead.

    /// y is always flipped (Vision is y-up). x is flipped ONLY when the
    /// source was not already mirrored — an external USB webcam or a
    /// Continuity Camera is not auto-mirrored, and without this every x
    /// would be silently wrong for those devices.
    static func normalize(_ p: CGPoint, mirrored: Bool) -> CGPoint {
        let x = mirrored ? p.x : 1 - p.x
        return CGPoint(x: x, y: 1 - p.y)
    }

    /// A Vision rect's TOP edge is at y-up `maxY`, which becomes viewer
    /// `1 - maxY`. When not mirrored, the rect's right edge (`maxX`) becomes
    /// the new left edge, so the new `minX` is `1 - maxX`. Width and height
    /// are unchanged either way.
    static func normalize(_ r: CGRect, mirrored: Bool) -> CGRect {
        let minX = mirrored ? r.minX : 1 - r.maxX
        return CGRect(x: minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Maps a viewer-space mask column back to the column to sample from the
    /// (unflipped) segmentation buffer. When `mirrored` is false the columns
    /// must be reversed the same way `normalize(_:mirrored:)` reverses x, or
    /// the mask and the landmarks it's compared against would disagree about
    /// which side of the frame is which.
    static func sourceColumn(forViewerColumn c: Int, cols: Int, mirrored: Bool) -> Int {
        mirrored ? c : (cols - 1 - c)
    }

    private func extractHand(mirrored: Bool) -> HandGeometry? {
        guard let obs = handRequest.results?.first else { return nil }
        let tipJoints: [VNHumanHandPoseObservation.JointName] =
            [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        var tips: [CGPoint] = []
        for joint in tipJoints {
            if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                tips.append(Self.normalize(CGPoint(x: p.location.x, y: p.location.y), mirrored: mirrored))
            }
        }
        return tips.isEmpty ? nil : HandGeometry(fingertips: tips)
    }

    private func extractFace(mirrored: Bool) -> FaceGeometry? {
        guard let face = faceRequest.results?.first else { return nil }
        let box = face.boundingBox   // Vision space: normalized, origin bottom-left
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let pts = region?.pointsInImage(imageSize: CGSize(width: 1, height: 1)),
                  !pts.isEmpty else { return nil }
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
        }
        let nose = centroid(face.landmarks?.nose)
            ?? CGPoint(x: box.midX, y: box.midY)
        let mouth = centroid(face.landmarks?.outerLips)
            ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.2)
        return FaceGeometry(box: Self.normalize(box, mirrored: mirrored),
                             nose: Self.normalize(nose, mirrored: mirrored),
                             mouth: Self.normalize(mouth, mirrored: mirrored))
    }

    /// Downsamples the person-segmentation mask (OneComponent8, 0..255,
    /// person = high) to a fixed `maskCols` x `maskRows` boolean grid.
    ///
    /// The mask buffer is sampled top-down and stored row-major with row 0 =
    /// top. In viewer space y=0 is also the top, so the row order is
    /// correct with no flip needed — `HairMask.isPerson` maps its row index
    /// as a direct (unflipped) scale of y for exactly this reason.
    ///
    /// Columns are a different story: the buffer's column order matches the
    /// SOURCE (unmirrored) frame, so when `mirrored` is false the column
    /// sampled for a given viewer-space column must be reversed via
    /// `sourceColumn(forViewerColumn:cols:mirrored:)`, or the mask would be
    /// mirrored relative to every landmark this type also emits.
    private func extractHairMask(mirrored: Bool) -> HairMask? {
        guard let observation = segmentationRequest.results?.first else { return nil }
        let mask = observation.pixelBuffer

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard maskWidth > 0, maskHeight > 0 else { return nil }

        let cols = Self.maskCols, rows = Self.maskRows
        let buffer = base.assumingMemoryBound(to: UInt8.self)
        var cells = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            let my = min(maskHeight - 1, Int((CGFloat(r) + 0.5) / CGFloat(rows) * CGFloat(maskHeight)))
            for c in 0..<cols {
                let sourceCol = Self.sourceColumn(forViewerColumn: c, cols: cols, mirrored: mirrored)
                let mx = min(maskWidth - 1,
                             Int((CGFloat(sourceCol) + 0.5) / CGFloat(cols) * CGFloat(maskWidth)))
                let value = buffer[my * bytesPerRow + mx]
                cells[r * cols + c] = value > 127
            }
        }
        return HairMask(cols: cols, rows: rows, cells: cells)
    }
}
