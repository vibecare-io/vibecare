import CoreGraphics
import VCKStubs

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
///
/// Post-cutover its input is a `VisionFrame` — one capture frame joined
/// across `vision.face.v1`, `vision.hands.v1` and `vision.segmentation.v1`
/// by `Header.seq` — instead of a locally-produced `LandmarkFrame`. The
/// arithmetic below is byte-for-byte what shipped before that change: the
/// radius formula, the per-fingertip first-match-wins order (nose → mouth →
/// hair) and the above-the-forehead guard are all unchanged, because the
/// coordinates arriving over the bus are in the same space the extractor
/// used to emit.
public struct BFRBDetector {
    /// 0…1. Trigger radius scales from 0.04 (low) to 0.12 (high) of frame size.
    public var sensitivity: Double

    public init(sensitivity: Double) {
        self.sensitivity = sensitivity
    }

    public func detect(_ frame: VisionFrame, enabled: Set<BFRBBehavior>) -> DetectionResult? {
        guard let face = frame.face, !frame.fingertips.isEmpty else { return nil }
        let radius = 0.04 + 0.08 * max(0, min(1, sensitivity))

        for tip in frame.fingertips {
            if enabled.contains(.nosePicking), distance(tip, face.nose) <= radius {
                return DetectionResult(behavior: .nosePicking, point: tip)
            }
            if enabled.contains(.nailBiting), distance(tip, face.mouth) <= radius {
                return DetectionResult(behavior: .nailBiting, point: tip)
            }
            if enabled.contains(.hairPulling), isHairContact(tip, face: face, mask: frame.segmentation) {
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
    /// when no mask is available — which post-cutover means either that
    /// nobody requested `vision.segmentation.v1` or that the provider
    /// published the empty "no person segmented" frame. Both read the same
    /// way here, and both did before: an unavailable mask must not silently
    /// disable hair-pulling detection.
    private func isHairContact(_ p: CGPoint, face: FaceAnchors, mask: VCTSegmentationFrame?) -> Bool {
        guard p.y < face.box.minY else { return false }   // above the forehead (viewer space)
        if let mask, mask.hasGrid {
            return mask.isPerson(atNormalized: p)                 // on the head/hair silhouette
        }
        return Self.hairZone(for: face.box).contains(p)           // graceful fallback (no mask)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return Double((dx * dx + dy * dy).squareRoot())
    }
}
