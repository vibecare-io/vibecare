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

    // MARK: - Detection-notification presentation
    //
    // The icon/copy shown by the VibeNotify alert on a confirmed detection
    // (see VibeNotifyConfig.showBFRBAlert). Kept here as the single source of
    // truth so the visuals and the behavior model never drift apart.

    /// SF Symbol shown as the notification's icon.
    var alertIcon: String {
        switch self {
        case .nailBiting:  return "hand.raised.fill"
        case .nosePicking: return "nose.fill"
        case .hairPulling: return "comb.fill"
        }
    }

    /// Warm, encouraging redirection used as the notification message.
    var nudge: String {
        switch self {
        case .nailBiting:  return "Take a breath — hands down 💛"
        case .nosePicking: return "Ease off — hands away 💛"
        case .hairPulling: return "Gently — hands down 💛"
        }
    }

    /// Bundled icon id used as this behavior's default alert icon
    /// (matches the backend catalog id and the /api/icons/<id>.svg path).
    var defaultIconId: String {
        switch self {
        case .nailBiting:  return "nail-biting"
        case .nosePicking: return "nose-picking"
        case .hairPulling: return "hair-pulling"
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
