import Vision
import CoreVideo
import Logging

/// Runs Vision hand-pose + face-landmark requests on a pixel buffer and
/// reduces the results to the few points BFRB detection needs.
/// Impure (talks to Vision); the pure geometry lives in BFRBDetector.
struct VisionLandmarkExtractor {
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
    private let logger = Logger(label: "com.vibecare.vision")

    /// Fixed downsample resolution for the hair-mask grid — coarse enough to
    /// be cheap to sample/draw per frame, fine enough for a head silhouette.
    private static let maskCols = 64
    private static let maskRows = 48

    func analyze(_ pixelBuffer: CVPixelBuffer) -> LandmarkFrame {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([handRequest, faceRequest, segmentationRequest])
        } catch {
            logger.debug("Vision perform failed: \(error)")
            return LandmarkFrame(hand: nil, face: nil, imageSize: imageSize)
        }
        return LandmarkFrame(hand: extractHand(), face: extractFace(), imageSize: imageSize,
                              hairMask: extractHairMask())
    }

    private func extractHand() -> HandGeometry? {
        guard let obs = handRequest.results?.first else { return nil }
        let tipJoints: [VNHumanHandPoseObservation.JointName] =
            [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
        var tips: [CGPoint] = []
        for joint in tipJoints {
            if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                tips.append(CGPoint(x: p.location.x, y: p.location.y))
            }
        }
        return tips.isEmpty ? nil : HandGeometry(fingertips: tips)
    }

    private func extractFace() -> FaceGeometry? {
        guard let face = faceRequest.results?.first else { return nil }
        let box = face.boundingBox   // normalized, origin bottom-left
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
        return FaceGeometry(box: box, nose: nose, mouth: mouth)
    }

    /// Downsamples the person-segmentation mask (OneComponent8, 0..255,
    /// person = high) to a fixed `maskCols` x `maskRows` boolean grid in
    /// "row 0 = top" order, matching `HairMask.isPerson`'s y-up mapping.
    /// Sampling the mask buffer top-down (my measured from the buffer's
    /// row 0) and storing row-major with row 0 first keeps the grid's row
    /// order aligned with the buffer's own row order — no flip needed here;
    /// the y-up/y-down reconciliation happens inside `HairMask.isPerson`.
    private func extractHairMask() -> HairMask? {
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
                let mx = min(maskWidth - 1, Int((CGFloat(c) + 0.5) / CGFloat(cols) * CGFloat(maskWidth)))
                let value = buffer[my * bytesPerRow + mx]
                cells[r * cols + c] = value > 127
            }
        }
        return HairMask(cols: cols, rows: rows, cells: cells)
    }
}
