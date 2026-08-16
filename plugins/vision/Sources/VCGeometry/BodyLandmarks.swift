import Foundation
import VCKStubs

/// The 19 body-pose joints, in the order `proto/topics/v1/vision.proto`
/// declares them. That order is NORMATIVE and defined by the proto, not by
/// Apple, so unlike the face constellation these indices can be — and here
/// are — pinned in code.
///
/// "left" and "right" are the SUBJECT's. In viewer space the preview is
/// mirrored, so the subject's left shoulder appears on the viewer's left, at
/// the smaller x.
public enum BodyJoint: Int, CaseIterable, Sendable {
    case nose = 0
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case root
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
}

/// A confidence-gated view over one published `BodyPoseFrame`.
///
/// Body pose drops individual joints constantly — a desk edge hides the elbows,
/// the frame edge cuts the hips, hair covers an ear — and an undetected joint is
/// still published, at whatever the model last guessed, with a low confidence.
/// Those coordinates are fiction. Reading them anyway is how a "shoulder angle"
/// ends up describing the back of a chair, so every accessor here gates on
/// confidence and returns `nil` rather than a plausible-looking lie.
///
/// An EMPTY `joints` array is the valid "no body detected" message, and every
/// accessor returns `nil` for it. A short array (a provider that published
/// fewer than 19) is handled the same way per joint rather than rejected
/// outright, so a partial frame still yields whatever it genuinely contains.
public struct BodyLandmarks: Sendable {
    /// Matches the gate `VisionLandmarkExtractor` has shipped on hand joints;
    /// kept identical here so one number governs "is this landmark real"
    /// across the provider rather than two that drift.
    public static let defaultMinimumConfidence: Float = 0.3

    public let joints: [VCTJoint]
    public let minimumConfidence: Float

    public init(joints: [VCTJoint], minimumConfidence: Float = BodyLandmarks.defaultMinimumConfidence) {
        self.joints = joints
        self.minimumConfidence = minimumConfidence
    }

    public init(frame: VCTBodyPoseFrame,
                minimumConfidence: Float = BodyLandmarks.defaultMinimumConfidence) {
        self.init(joints: frame.joints, minimumConfidence: minimumConfidence)
    }

    /// `nil` when the joint was not published or did not clear the confidence
    /// gate.
    public func point(_ joint: BodyJoint) -> VCTPoint? {
        let index = joint.rawValue
        guard index < joints.count else { return nil }
        let j = joints[index]
        guard j.confidence >= minimumConfidence else { return nil }
        return j.point
    }

    /// The midpoint of a pair of joints, or `nil` unless BOTH cleared the gate.
    /// Deliberately not "whichever one we have": a one-eared midpoint is offset
    /// by half a head width and nothing downstream could tell.
    public func midpoint(_ a: BodyJoint, _ b: BodyJoint) -> VCTPoint? {
        guard let pa = point(a), let pb = point(b) else { return nil }
        var out = VCTPoint()
        out.x = (pa.x + pb.x) / 2
        out.y = (pa.y + pb.y) / 2
        return out
    }
}

/// Posture geometry over body-pose landmarks.
///
/// Both signals here are measurements, not verdicts. "Slouching for four
/// minutes" is a judgement about behaviour with no right answer on a clip, so
/// it belongs to the `postures` plugin and never to the provider (design §2).
public enum BodySignals {
    /// The shoulder line's tilt off horizontal, in degrees, folded into
    /// (-90, 90].
    ///
    /// **Positive means the subject's RIGHT shoulder sits lower on screen**,
    /// the same sign convention as `HeadPose.roll`, so a consumer comparing
    /// head tilt against shoulder tilt is comparing like with like.
    ///
    /// `nil` when either shoulder is missing or below the confidence gate, or
    /// when the two coincide — a zero-length line has no tilt, and reporting
    /// 0 there would be indistinguishable from perfectly level shoulders.
    public static func shoulderAngleDegrees(_ body: BodyLandmarks, aspect: Aspect) -> Float? {
        guard let left = body.point(.leftShoulder), let right = body.point(.rightShoulder) else {
            return nil
        }
        guard let angle = aspect.delta(from: left, to: right).angleDegrees else { return nil }
        return Geometry.foldToHorizontal(angle)
    }

    /// How far the head sits off the shoulder line, in frame-height units,
    /// measured perpendicular to that line so head tilt and shoulder tilt do
    /// not contaminate it. Positive means the head is on the ABOVE side.
    ///
    /// This is the front-view observable of forward-head posture. True sagittal
    /// translation is along the camera's optical axis and a webcam cannot see
    /// it at all; what a webcam does see is the head sinking toward the
    /// shoulders as it comes forward and down. **The value therefore DECREASES
    /// as the head moves forward**, which is the opposite of what the field
    /// name `neck_forward` suggests and is called out here because a consumer
    /// getting that backwards produces a nudge that fires when the user is
    /// sitting well.
    ///
    /// No baseline is baked in. "Neutral" varies with build, seating and camera
    /// height, and picking a constant for it would be exactly the fabricated
    /// judgement design §2 forbids — establishing a per-user neutral is the
    /// consumer's job.
    ///
    /// Both ears are required rather than one, and the nose is deliberately not
    /// used as a fallback: the nose swings with yaw, so a head-turn would read
    /// as a posture change, and quietly substituting a different measurement
    /// under the same field name is worse than leaving it absent.
    public static func headOverShoulders(_ body: BodyLandmarks, aspect: Aspect) -> Float? {
        guard let left = body.point(.leftShoulder),
              let right = body.point(.rightShoulder),
              let ears = body.midpoint(.leftEar, .rightEar) else { return nil }
        let shoulderLine = aspect.delta(from: left, to: right)
        let width = shoulderLine.length
        guard width > Geometry.epsilon else { return nil }
        let axis = shoulderLine * (1 / width)
        // Cross product is positive clockwise (y down), so a head ABOVE the
        // line yields a negative value — negate to make "up" positive.
        return -axis.cross(aspect.delta(from: left, to: ears))
    }
}
