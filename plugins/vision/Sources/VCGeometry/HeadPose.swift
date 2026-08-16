import Foundation
import VCKStubs

/// Head orientation in degrees, viewer space.
///
/// `yaw` is optional and the other two are not, which is not an oversight:
/// there is a real head attitude — looking down far enough that the nose points
/// at the camera — where a single view carries no yaw information at all, while
/// pitch and roll stay perfectly well determined. Reporting a number there would
/// be inventing one. See `HeadPoseEstimator.maximumYawAmplification`.
public struct HeadPose: Sendable, Equatable {
    /// Rotation about the vertical axis. **Positive = the subject turned
    /// toward their own right**, which in a mirrored preview moves the nose
    /// toward the viewer's right. Zero when facing the camera. `nil` when the
    /// head's pitch has hidden the cue yaw is read from.
    public var yaw: Float?
    /// Rotation about the lateral axis. **Positive = looking UP.** Zero when
    /// the face is level with the camera.
    public var pitch: Float
    /// Rotation in the image plane. **Positive = tilted toward the subject's
    /// own right shoulder**, which puts their right eye lower on screen. Zero
    /// when the eyes are level.
    public var roll: Float

    public init(yaw: Float?, pitch: Float, roll: Float) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// The anthropometric ratios that turn four 2D landmarks into three angles.
///
/// Yaw and pitch are recovered from how far the nose and mouth sit from the eye
/// midpoint under a weak-perspective (orthographic) projection of a rigid head.
/// That needs the head's proportions, and a single camera cannot measure them,
/// so they are constants — expressed as ratios to the inter-ocular distance so
/// they are free of both scale and units.
///
/// The defaults are adult means: inter-ocular distance ~63 mm, the `nose`
/// region's centroid sitting ~42 mm below the eye line and ~22 mm forward of
/// it, and the outer-lip centroid ~70 mm below. They are exposed rather than
/// buried because they are the model's only tunable, and because whoever
/// changes what `FaceLandmarks.nose` means must recalibrate them.
///
/// ## What this is and is not
///
/// It is a deterministic geometric reading with a right answer on a fixture:
/// zero at frontal, monotonic through the useful range, and unaffected by
/// scale, roll, or the camera's aspect ratio. It is not a calibrated pose
/// estimate — a subject with an unusually long nose reads a few degrees off,
/// and accuracy degrades past roughly ±40 degrees where a single view stops
/// carrying enough information. Consumers should treat it as a per-user
/// relative measure, which is what "looking away from the screen" needs anyway.
public struct HeadPoseModel: Sendable, Equatable {
    /// Nose centroid's drop below the eye line, in inter-ocular distances.
    public var noseDrop: Float
    /// Nose centroid's forward projection from the eye plane, in inter-ocular
    /// distances. This is the term that makes yaw and pitch observable at all;
    /// a perfectly flat face carries no monocular pose information.
    public var noseProjection: Float
    /// Outer-lip centroid's drop below the eye line, in inter-ocular distances.
    /// Its only job is to give pitch a foreshortening reference the nose's own
    /// projection cannot supply.
    public var mouthDrop: Float

    public init(noseDrop: Float, noseProjection: Float, mouthDrop: Float) {
        self.noseDrop = noseDrop
        self.noseProjection = noseProjection
        self.mouthDrop = mouthDrop
    }

    public static let `default` = HeadPoseModel(noseDrop: 42.0 / 63.0,
                                                noseProjection: 22.0 / 63.0,
                                                mouthDrop: 70.0 / 63.0)
}

/// Recovers yaw, pitch and roll from eye centres, nose and mouth.
///
/// ## Derivation
///
/// Image axes are viewer space: +x is the viewer's right (and, because the
/// preview is mirrored, the SUBJECT's right too), +y is DOWN, +z is into the
/// screen. Put the eye midpoint at the origin and work in units of the
/// inter-ocular distance `d`: the eyes sit at `±1/2` along the head's right
/// vector, the nose at `noseDrop` below the eye line and `noseProjection` in
/// front of it, the mouth at `mouthDrop` below. Compose the head's attitude as
/// a yaw about the world vertical applied to an already-pitched head, which is
/// how a neck actually works.
///
/// Projecting that orthographically gives, with `a = noseDrop`,
/// `b = noseProjection`, `c = mouthDrop`:
///
/// ```
///   eye line       = d·cos(yaw), horizontal, rolled by `roll`
///   nose  vertical = d·(a·cos(pitch) − b·sin(pitch))
///   mouth vertical = d·(c·cos(pitch))
///   nose  horizonl = d·(a·sin(pitch) + b·cos(pitch))·sin(yaw)
/// ```
///
/// * **Roll** is read straight off the eye line: `atan2(Δy, Δx)` of
///   left-eye→right-eye. Everything after is measured in a de-rolled frame, so
///   a tilted head cannot leak into the other two.
/// * **Pitch** comes from the two vertical offsets. Solving the pair for
///   `sin(pitch)` and `cos(pitch)` and handing both to `atan2` yields
///   `atan2(a·w − c·v, b·w)`, in which the common factor `d` cancels — so pitch
///   needs no distance estimate, and, because neither vertical offset depends
///   on yaw, **no yaw estimate either**. It is exact and monotonic across the
///   whole range. The tempting single-landmark form (nose only) saturates near
///   26 degrees and then reverses, which is precisely the failure the mouth
///   term removes.
/// * **Yaw** then divides the nose's horizontal offset by the head's forward
///   extent as pitch has left it, `K = a·sin(pitch) + b·cos(pitch)`, times the
///   PROJECTED eye separation. The two foreshortenings cancel exactly:
///   `tan(yaw) = Δx_nose / (K · d_projected)`. Ignoring pitch's effect on `K`
///   is the classic coupling bug — at 30 degrees of pitch it overstates yaw by
///   about 70% — and computing pitch first is what avoids it.
///
/// `K` shrinks as the subject looks down (the nose tip swings from "in front
/// of the eyes" toward "directly below them") and passes through zero near
/// −28 degrees of pitch. There, yaw is genuinely unobservable, and the
/// estimator says so by returning `nil` for it rather than amplifying noise.
public enum HeadPoseEstimator {
    /// Below this the eye line carries no direction and the whole construction
    /// collapses — two coincident eye centres mean the detector lost the face,
    /// not that the head is frontal.
    public static let minimumEyeSeparation: Float = 1e-4

    /// How much yaw sensitivity may be amplified, relative to a frontal head,
    /// before yaw is reported as unrecoverable. Yaw's error scales as
    /// `noseProjection / K`, so a cap of 5 means at most five degrees of
    /// reported yaw per degree of true yaw error.
    public static let maximumYawAmplification: Float = 5

    public static func estimate(leftEye: VCTPoint,
                                rightEye: VCTPoint,
                                nose: VCTPoint,
                                mouth: VCTPoint,
                                aspect: Aspect,
                                model: HeadPoseModel = .default) -> HeadPose? {
        let eyeLine = aspect.delta(from: leftEye, to: rightEye)
        let projectedSeparation = eyeLine.length
        guard projectedSeparation > minimumEyeSeparation else { return nil }
        guard let roll = eyeLine.angleDegrees else { return nil }

        // De-roll about the eye midpoint, so the vertical offsets below are
        // purely pitch's doing and the horizontal one purely yaw's.
        let eyeMid = (aspect.vector(leftEye) + aspect.vector(rightEye)) * 0.5
        let c = cos(Geometry.radians(roll))
        let s = sin(Geometry.radians(roll))
        func deRolled(_ p: VCTPoint) -> Vector2 {
            let v = aspect.vector(p) - eyeMid
            return Vector2(x: v.x * c + v.y * s, y: -v.x * s + v.y * c)
        }
        let noseRel = deRolled(nose)
        let mouthRel = deRolled(mouth)

        // Pitch, from the vertical offsets alone. Scale cancels; yaw never
        // enters.
        let sinTerm = model.noseDrop * mouthRel.y - model.mouthDrop * noseRel.y
        let cosTerm = model.noseProjection * mouthRel.y
        guard abs(sinTerm) > Geometry.epsilon || abs(cosTerm) > Geometry.epsilon else {
            // Nose, mouth and eye midpoint have collapsed onto one point.
            // There is no face here to have an orientation.
            return nil
        }
        let pitch = Geometry.degrees(atan2(sinTerm, cosTerm))

        // Yaw, against the forward extent that pitch has left the nose.
        let pitchRadians = Geometry.radians(pitch)
        let forwardExtent = model.noseDrop * sin(pitchRadians) + model.noseProjection * cos(pitchRadians)
        let minimumForwardExtent = model.noseProjection / maximumYawAmplification
        let yaw: Float?
        if forwardExtent >= minimumForwardExtent {
            yaw = Geometry.degrees(atan2(noseRel.x, forwardExtent * projectedSeparation))
        } else {
            yaw = nil
        }

        return HeadPose(yaw: yaw, pitch: pitch, roll: roll)
    }

    /// The pose of a validated face frame. `nil` when the constellation did not
    /// carry every region the model needs — which leaves `yaw`/`pitch`/`roll`
    /// absent rather than zero, and a consumer reading absent as zero would see
    /// a user staring dead ahead while they looked away.
    public static func estimate(face: FaceLandmarks,
                                aspect: Aspect,
                                model: HeadPoseModel = .default) -> HeadPose? {
        guard let leftEye = face.eyeCentre(.left),
              let rightEye = face.eyeCentre(.right),
              let nose = face.nose,
              let mouth = face.mouth else { return nil }
        return estimate(leftEye: leftEye,
                        rightEye: rightEye,
                        nose: nose,
                        mouth: mouth,
                        aspect: aspect,
                        model: model)
    }
}
