import Foundation

// Everything geometric that used to live here moved to the `vision` plugin
// when vibecheck stopped owning the camera (vision-provider design §8):
//
//   ViewerSpace                      -> plugins/vision/Sources/VCGeometry/
//   HandGeometry, FaceGeometry,      -> deleted both sides, replaced by the
//   HairMask, LandmarkFrame             generated proto types of §4
//                                       (VCTFaceFrame / VCTHandsFrame /
//                                       VCTSegmentationFrame in VCKStubs)
//
// What stays is the one thing in that file that was never geometry: the
// behaviour model. `BFRBBehavior` is a PRODUCT noun — "nose-picking" is a
// judgement about behaviour, which §2 says a provider may never publish —
// so it belongs to the detector that makes the judgement, and to nothing
// upstream of it.
//
// The proto -> viewer-space adaptation that replaces the deleted types lives
// in `VisionFrames.swift`, next to the join that produces it.

public enum BFRBBehavior: String, CaseIterable, Sendable, Identifiable {
    case nailBiting, nosePicking, hairPulling
    public var id: String { rawValue }
    public var label: String {
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
    public var alertIcon: String {
        switch self {
        case .nailBiting:  return "hand.raised.fill"
        case .nosePicking: return "nose.fill"
        case .hairPulling: return "comb.fill"
        }
    }

    /// Warm, encouraging redirection used as the notification message.
    public var nudge: String {
        switch self {
        case .nailBiting:  return "Take a breath — hands down 💛"
        case .nosePicking: return "Ease off — hands away 💛"
        case .hairPulling: return "Gently — hands down 💛"
        }
    }

    /// Bundled icon id used as this behavior's default alert icon
    /// (matches the backend catalog id and the /api/icons/<id>.svg path).
    public var defaultIconId: String {
        switch self {
        case .nailBiting:  return "nail-biting"
        case .nosePicking: return "nose-picking"
        case .hairPulling: return "hair-pulling"
        }
    }

    /// Which `vision.*` topics this behaviour needs before it can be
    /// evaluated at all. Every behaviour needs a face (the anchors it
    /// measures against) and hands (the fingertips it measures); only
    /// hair-pulling additionally needs the person-segmentation mask.
    ///
    /// This is what makes `vision.request.v1` truthful rather than a blanket
    /// "give me everything": a user who only wants nail-biting must not pay
    /// for `VNGeneratePersonSegmentationRequest`. See `VisionRequest.topics`,
    /// which unions this across the enabled behaviours.
    public var requiredVisionTopics: Set<VisionTopic> {
        switch self {
        case .nailBiting, .nosePicking: return [.face, .hands]
        case .hairPulling:              return [.face, .hands, .segmentation]
        }
    }
}
