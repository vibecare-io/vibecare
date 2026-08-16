import Foundation

/// The topic consumers publish their desired state on, and the only topic this
/// plugin subscribes to. Declared in `subscribes:` here and in `publishes:` by
/// every consumer — publishing an undeclared topic is a logged error and a
/// dropped message, which on this channel silently means "vision never runs
/// the model I need".
public let VisionRequestTopic = "vision.request.v1"

/// The five topics this provider publishes.
///
/// One topic per **Vision request**, because ANE cost is per-request, not per
/// landmark — that one-to-one mapping is what makes the kernel's demand
/// refcount a truthful cost model. `signals` is the exception and is free:
/// pure math over landmarks some other consumer already paid for, so it
/// constructs no model of its own (`model == nil`).
public enum VisionTopic: String, CaseIterable, Sendable, Codable, Hashable, Comparable {
    case face = "vision.face.v1"
    case hands = "vision.hands.v1"
    case bodyPose = "vision.body_pose.v1"
    case segmentation = "vision.segmentation.v1"
    case signals = "vision.signals.v1"

    /// The `VNRequest` subclass this topic costs, or `nil` for a topic that
    /// costs no inference. Callers use `model != nil` to decide whether a
    /// topic contributes to the set of models that must be constructed —
    /// never a hard-coded list, which is how a sixth topic added later ends
    /// up quietly running a model nobody released.
    public var model: String? {
        switch self {
        case .face: return "VNDetectFaceLandmarksRequest"
        case .hands: return "VNDetectHumanHandPoseRequest"
        case .bodyPose: return "VNDetectHumanBodyPoseRequest"
        case .segmentation: return "VNGeneratePersonSegmentationRequest"
        case .signals: return nil
        }
    }

    /// The wire topic name. Spelled out rather than left implicit at every
    /// call site so a reader never has to check whether `rawValue` happened
    /// to be the topic or the case name.
    public var name: String { rawValue }

    /// Ordering is by topic name, so every readout (`/api/state`, the log
    /// lines, the test expectations) lists topics in one stable order rather
    /// than dictionary order, which differs run to run.
    public static func < (lhs: VisionTopic, rhs: VisionTopic) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The set of topics whose payload comes out of a `VNRequest`. `signals` is
/// deliberately absent.
public let VisionModelTopics: Set<VisionTopic> = Set(VisionTopic.allCases.filter { $0.model != nil })
