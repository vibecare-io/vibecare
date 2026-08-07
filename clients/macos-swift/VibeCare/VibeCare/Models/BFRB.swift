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
struct LandmarkFrame: Sendable { var hand: HandGeometry?; var face: FaceGeometry? }
