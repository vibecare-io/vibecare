import Foundation
import VCKStubs

/// Assembles one `vision.signals.v1` payload from whichever tiers ran this
/// frame.
///
/// # The rule this type exists to enforce
///
/// **Every field is optional, and ABSENT IS NOT ZERO.** A field is absent when
/// the model that feeds it is not running, or ran and could not see what the
/// signal is made of. A consumer reading absent as `0.0` sees a permanently
/// closed eye, a head staring dead ahead, and a perfectly level pair of
/// shoulders — three false readings that all look like plausible data.
///
/// So this type never writes a fallback. There is no `?? 0` anywhere below and
/// there must never be one: assigning to a SwiftProtobuf optional field sets its
/// presence bit, so `signals.earL = 0` and "we did not measure the left eye"
/// are different messages on the wire, and the second one is spelled by not
/// assigning at all.
///
/// # What the arguments mean
///
/// Each frame argument is `nil` when that Vision request is **not running**
/// (nobody requested the topic, so the model was never constructed) and
/// non-`nil` when it ran — even if it saw nothing. Both cases leave the derived
/// fields absent, which is correct, because both mean "unknown". The
/// distinction that matters to consumers is preserved where it belongs: by
/// whether a message appears on `vision.face.v1` at all, not by a sentinel in
/// here.
///
/// # Scope
///
/// Nothing in this file judges behaviour. There is no `isBlinking`, no
/// `isSlouching`, no `nailBiting`; each fails design §2's first and third tests
/// (a measurable property of the body; a right answer on a recorded clip), and
/// that triple is the only thing keeping this tier from rotting into a junk
/// drawer.
public struct SignalsBuilder: Sendable {
    public var headPoseModel: HeadPoseModel
    public var minimumHandJointConfidence: Float
    public var minimumBodyJointConfidence: Float

    public init(headPoseModel: HeadPoseModel = .default,
                minimumHandJointConfidence: Float = HandLandmarks.defaultMinimumConfidence,
                minimumBodyJointConfidence: Float = BodyLandmarks.defaultMinimumConfidence) {
        self.headPoseModel = headPoseModel
        self.minimumHandJointConfidence = minimumHandJointConfidence
        self.minimumBodyJointConfidence = minimumBodyJointConfidence
    }

    /// - Parameters:
    ///   - header: the frame header, shared verbatim with every other topic
    ///     derived from this frame. Its `seq` is what lets a consumer join the
    ///     tiers, so it is copied rather than regenerated.
    ///   - face: the face frame published this tick, or `nil` if the face model
    ///     is not running.
    ///   - faceLayout: where each region sits inside `face.points`. `nil`, or a
    ///     layout whose total disagrees with the published point count, leaves
    ///     every face-derived signal absent — indexing into a constellation
    ///     nobody validated is how an eyebrow gets reported as an eye.
    ///   - hands: the hands frame published this tick, or `nil` if the hand
    ///     model is not running.
    ///   - body: the body-pose frame published this tick, or `nil` if the
    ///     body model is not running.
    public func signals(header: VCTHeader,
                        face: VCTFaceFrame? = nil,
                        faceLayout: FaceLandmarkLayout? = nil,
                        hands: VCTHandsFrame? = nil,
                        body: VCTBodyPoseFrame? = nil) -> VCTSignals {
        var signals = VCTSignals()
        signals.header = header

        // Distances and angles are aspect-corrected against the frame this
        // header describes, so a signal means the same thing on a 16:9 webcam
        // and a 4:3 one.
        let aspect = Aspect(header: header)

        let landmarks: FaceLandmarks? = {
            guard let face, let faceLayout else { return nil }
            return FaceLandmarks(frame: face, layout: faceLayout)
        }()

        if let landmarks {
            if let earL = EyeAspectRatio.value(of: landmarks, eye: .left, aspect: aspect) {
                signals.earL = earL
            }
            if let earR = EyeAspectRatio.value(of: landmarks, eye: .right, aspect: aspect) {
                signals.earR = earR
            }
            if let pose = HeadPoseEstimator.estimate(face: landmarks, aspect: aspect, model: headPoseModel) {
                // yaw alone can be unrecoverable at a pitch that hides the cue
                // it is read from, while pitch and roll stay well determined.
                if let yaw = pose.yaw {
                    signals.yaw = yaw
                }
                signals.pitch = pose.pitch
                signals.roll = pose.roll
            }
        }

        if let body {
            let landmarks = BodyLandmarks(frame: body, minimumConfidence: minimumBodyJointConfidence)
            if let angle = BodySignals.shoulderAngleDegrees(landmarks, aspect: aspect) {
                signals.shoulderAngle = angle
            }
            if let neck = BodySignals.headOverShoulders(landmarks, aspect: aspect) {
                signals.neckForward = neck
            }
        }

        // Fingertip distances need BOTH models: either one missing makes the
        // distance undefined rather than large.
        if let hands, let landmarks {
            if let nose = landmarks.nose,
               let d = HandSignals.minimumFingertipDistance(from: hands,
                                                            to: nose,
                                                            aspect: aspect,
                                                            minimumConfidence: minimumHandJointConfidence) {
                signals.fingertipToNose = d
            }
            if let mouth = landmarks.mouth,
               let d = HandSignals.minimumFingertipDistance(from: hands,
                                                            to: mouth,
                                                            aspect: aspect,
                                                            minimumConfidence: minimumHandJointConfidence) {
                signals.fingertipToMouth = d
            }
        }

        return signals
    }
}
