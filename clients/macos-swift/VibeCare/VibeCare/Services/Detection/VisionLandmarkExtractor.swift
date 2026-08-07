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
    private let logger = Logger(label: "com.vibecare.vision")

    func analyze(_ pixelBuffer: CVPixelBuffer) -> LandmarkFrame {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([handRequest, faceRequest])
        } catch {
            logger.debug("Vision perform failed: \(error)")
            return LandmarkFrame(hand: nil, face: nil, imageSize: imageSize)
        }
        return LandmarkFrame(hand: extractHand(), face: extractFace(), imageSize: imageSize)
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
}
