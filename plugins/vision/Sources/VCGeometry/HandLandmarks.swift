import Foundation
import VCKStubs

/// The 21 hand joints, in the order `proto/topics/v1/vision.proto` declares
/// them. NORMATIVE and defined by the proto, so index 8 is always the index
/// fingertip — the array is never short and never sparse.
public enum HandJoint: Int, CaseIterable, Sendable {
    case wrist = 0
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    /// The five joints that touch things.
    public static let fingertips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
}

/// A confidence-gated view over one published `Hand`.
///
/// `joint_confidence` is either empty (the provider does not report per-joint
/// confidence) or exactly as long as `joints`. Empty means UNKNOWN, not zero —
/// the correct fallback is the hand's frame-level confidence, not discarding
/// every joint — and that distinction is the whole reason this type exists
/// rather than a bare index into the array.
public struct HandLandmarks: Sendable {
    /// The gate `VisionLandmarkExtractor` has shipped on fingertips since the
    /// first BFRB detector. Kept at the same value so moving capture into the
    /// provider does not silently retune detection.
    public static let defaultMinimumConfidence: Float = 0.3

    public let hand: VCTHand
    public let minimumConfidence: Float

    public init(hand: VCTHand, minimumConfidence: Float = HandLandmarks.defaultMinimumConfidence) {
        self.hand = hand
        self.minimumConfidence = minimumConfidence
    }

    public var handedness: VCTHandedness { hand.handedness }

    /// `nil` when the joint was not published, or when the confidence that
    /// applies to it — per-joint if reported, otherwise the hand's own — is
    /// below the gate. A fingertip occluded behind the palm still has
    /// coordinates and they are fiction.
    public func point(_ joint: HandJoint) -> VCTPoint? {
        let index = joint.rawValue
        guard index < hand.joints.count else { return nil }
        let confidence: Float
        if hand.jointConfidence.count == hand.joints.count {
            confidence = hand.jointConfidence[index]
        } else {
            confidence = hand.confidence
        }
        guard confidence >= minimumConfidence else { return nil }
        return hand.joints[index]
    }

    /// Every fingertip that cleared the gate, in `HandJoint.fingertips` order.
    public var fingertips: [VCTPoint] {
        HandJoint.fingertips.compactMap { point($0) }
    }
}

/// Fingertip proximity geometry.
///
/// The distances are measurements. "Nose-picking, sixth today" is a judgement
/// about behaviour and belongs to `vibecheck`; the provider stops at how far
/// the nearest fingertip is from the nose.
public enum HandSignals {
    /// Confidence-gated fingertips across every hand in one frame.
    public static func fingertips(of frame: VCTHandsFrame,
                                  minimumConfidence: Float = HandLandmarks.defaultMinimumConfidence) -> [VCTPoint] {
        frame.hands.flatMap { HandLandmarks(hand: $0, minimumConfidence: minimumConfidence).fingertips }
    }

    /// Distance from the nearest fingertip to `target`, in frame-height units.
    ///
    /// `nil` when no fingertip cleared the gate — including the ordinary case
    /// of no hands in frame. That is the honest answer: the minimum of an empty
    /// set is not a large number, it is undefined, and a consumer that read
    /// absence as "hands are far away" would be right by accident today and
    /// wrong the moment the model drops a frame mid-gesture.
    public static func minimumFingertipDistance(from frame: VCTHandsFrame,
                                                to target: VCTPoint,
                                                aspect: Aspect,
                                                minimumConfidence: Float = HandLandmarks.defaultMinimumConfidence) -> Float? {
        var best: Float?
        for tip in fingertips(of: frame, minimumConfidence: minimumConfidence) {
            let d = aspect.distance(tip, target)
            if best == nil || d < best! { best = d }
        }
        return best
    }
}
