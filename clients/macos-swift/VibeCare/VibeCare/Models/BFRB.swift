import CoreGraphics

enum BFRBBehavior: String, CaseIterable, Sendable, Identifiable {
    case nailBiting, nosePicking, hairPulling
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nailBiting:  return "Nail-biting"
        case .nosePicking: return "Nose-picking"
        case .hairPulling: return "Hair-pulling"
        }
    }
}

/// All points are normalized [0,1] in Vision's coordinate space:
/// origin bottom-left, y increases upward.
struct HandGeometry: Sendable { var fingertips: [CGPoint] }
struct FaceGeometry: Sendable { var box: CGRect; var nose: CGPoint; var mouth: CGPoint }

/// A coarse boolean grid of the person-segmentation mask, in Vision's
/// normalized space (x right in [0,1], y UP in [0,1]). Row-major, row 0 = TOP
/// (y near 1). Pure value type so BFRBDetector stays testable.
struct HairMask: Sendable, Equatable {
    let cols: Int
    let rows: Int
    let cells: [Bool]   // count == cols*rows, row-major, row 0 = top

    func isPerson(atNormalized p: CGPoint) -> Bool {
        guard cols > 0, rows > 0, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return false }
        let col = min(cols - 1, max(0, Int(p.x * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int((1 - p.y) * CGFloat(rows)))) // y-up -> row 0 = top
        return cells[row * cols + col]
    }
}

struct LandmarkFrame: Sendable {
    var hand: HandGeometry?
    var face: FaceGeometry?
    /// Pixel-buffer dimensions the landmarks were computed against, used by
    /// the overlay to map normalized points through the aspect-fill crop.
    var imageSize: CGSize = .zero
    /// Coarse person-segmentation grid used to draw a head/hair-shaped
    /// overlay and to sample hair-pulling detection consistently with it.
    /// nil when segmentation is unavailable (falls back to the geometric
    /// hair zone).
    var hairMask: HairMask? = nil
}
