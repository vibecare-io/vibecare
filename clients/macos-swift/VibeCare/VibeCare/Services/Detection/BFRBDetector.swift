import CoreGraphics

struct DetectionResult: Sendable, Equatable {
    let behavior: BFRBBehavior
    let point: CGPoint
}

/// Pure fingertip-to-face-region geometry. All points normalized, Vision
/// coords (y up). No Vision/camera dependency → fully unit-testable.
struct BFRBDetector {
    /// 0…1. Trigger radius scales from 0.04 (low) to 0.12 (high) of frame size.
    var sensitivity: Double

    func detect(_ frame: LandmarkFrame, enabled: Set<BFRBBehavior>) -> DetectionResult? {
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

    /// Hair zone: a band above the forehead (y above box top), extended
    /// laterally past the temples by 15% of face width. Vision space (y up).
    /// Shared with `DetectionOverlay` so the drawn overlay and the actual
    /// detection trigger region can never drift apart.
    static func hairZone(for box: CGRect) -> CGRect {
        let pad = box.width * 0.15
        return CGRect(x: box.minX - pad,
                      y: box.maxY,
                      width: box.width + 2 * pad,
                      height: box.height * 0.5)
    }

    /// A fingertip counts as hair-pulling when it's above the forehead
    /// (excludes the face itself) AND lands on the person/hair silhouette.
    /// Prefers the segmentation mask; falls back to the geometric hair zone
    /// when no mask is available (segmentation unsupported/failed).
    private func isHairContact(_ p: CGPoint, face: FaceGeometry, mask: HairMask?) -> Bool {
        guard p.y > face.box.maxY else { return false }          // above the forehead only
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
