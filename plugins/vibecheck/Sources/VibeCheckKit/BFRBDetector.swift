import CoreGraphics

public struct DetectionResult: Sendable, Equatable {
    public let behavior: BFRBBehavior
    public let point: CGPoint

    public init(behavior: BFRBBehavior, point: CGPoint) {
        self.behavior = behavior
        self.point = point
    }
}

/// Pure fingertip-to-face-region geometry. All points normalized, VIEWER
/// coords (origin top-left, y down). No Vision/camera dependency → fully
/// unit-testable.
public struct BFRBDetector {
    /// 0…1. Trigger radius scales from 0.04 (low) to 0.12 (high) of frame size.
    public var sensitivity: Double

    public init(sensitivity: Double) {
        self.sensitivity = sensitivity
    }

    public func detect(_ frame: LandmarkFrame, enabled: Set<BFRBBehavior>) -> DetectionResult? {
        guard let hand = frame.hand, let face = frame.face else { return nil }
        let radius = 0.04 + 0.08 * max(0, min(1, sensitivity))

        for tip in hand.fingertips {
            if enabled.contains(.nosePicking), distance(tip, face.nose) <= radius {
                return DetectionResult(behavior: .nosePicking, point: tip)
            }
            if enabled.contains(.nailBiting), distance(tip, face.mouth) <= radius {
                return DetectionResult(behavior: .nailBiting, point: tip)
            }
            if enabled.contains(.hairPulling), isHairContact(tip, face: face, mask: frame.hairMask) {
                return DetectionResult(behavior: .hairPulling, point: tip)
            }
        }
        return nil
    }

    /// Hair zone: a band ABOVE the forehead in viewer space — from half a
    /// face-height above the box top, down to the box top — extended
    /// laterally past the temples by 15% of face width.
    public static func hairZone(for box: CGRect) -> CGRect {
        let pad = box.width * 0.15
        let height = box.height * 0.5
        return CGRect(x: box.minX - pad,
                      y: box.minY - height,
                      width: box.width + 2 * pad,
                      height: height)
    }

    /// A fingertip counts as hair-pulling when it's above the forehead
    /// (excludes the face itself) AND lands on the person/hair silhouette.
    /// Prefers the segmentation mask; falls back to the geometric hair zone
    /// when no mask is available (segmentation unsupported/failed).
    private func isHairContact(_ p: CGPoint, face: FaceGeometry, mask: HairMask?) -> Bool {
        guard p.y < face.box.minY else { return false }   // above the forehead (viewer space)
        if let mask, mask.cols > 0 {
            return mask.isPerson(atNormalized: p)                 // on the head/hair silhouette
        }
        return Self.hairZone(for: face.box).contains(p)           // graceful fallback (no mask)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return Double((dx * dx + dy * dy).squareRoot())
    }
}
