import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

// The synthetic head projects a known attitude to four 2D points; the estimator
// gets only those four points back. Recovering the attitude exercises the
// de-roll, the pitch-before-yaw ordering and both sign conventions at once.
//
// Optionals are unwrapped with `try #require`, never with `!`: a force-unwrap
// that trips takes the whole test process down and masks every later failure,
// which is a real hazard here because the estimator legitimately returns nil
// for degenerate input.

/// Float32 through a dozen trig calls; a twentieth of a degree is orders of
/// magnitude tighter than the model's own accuracy and still far above the
/// arithmetic's noise floor.
let poseTolerance: Float = 0.05

private func pose(_ p: SyntheticHead.Projection, aspect: Aspect = .square) throws -> HeadPose {
    try #require(HeadPoseEstimator.estimate(leftEye: p.leftEye,
                                            rightEye: p.rightEye,
                                            nose: p.nose,
                                            mouth: p.mouth,
                                            aspect: aspect))
}

@Test func aFrontalHeadReadsZeroOnAllThreeAxes() throws {
    let result = try pose(SyntheticHead().project(yaw: 0, pitch: 0, roll: 0))
    let yaw = try #require(result.yaw)
    #expect(isClose(yaw, 0, tolerance: angleTolerance))
    #expect(isClose(result.pitch, 0, tolerance: angleTolerance))
    #expect(isClose(result.roll, 0, tolerance: angleTolerance))
}

@Test func yawRoundTripsAndLeavesTheOtherAxesAtZero() throws {
    let head = SyntheticHead()
    for angle in [Float(-45), -35, -20, -8, 8, 20, 35, 45] {
        let result = try pose(head.project(yaw: angle, pitch: 0, roll: 0))
        let yaw = try #require(result.yaw)
        #expect(isClose(yaw, angle, tolerance: poseTolerance))
        #expect(isClose(result.pitch, 0, tolerance: poseTolerance))
        #expect(isClose(result.roll, 0, tolerance: poseTolerance))
    }
}

@Test func pitchRoundTripsAndLeavesTheOtherAxesAtZero() throws {
    // The range stops short of -27.6 degrees, where the nose passes through the
    // eye plane and yaw becomes unobservable; that boundary has its own test.
    let head = SyntheticHead()
    for angle in [Float(-20), -10, 10, 25, 40, 55] {
        let result = try pose(head.project(yaw: 0, pitch: angle, roll: 0))
        let yaw = try #require(result.yaw)
        #expect(isClose(result.pitch, angle, tolerance: poseTolerance))
        #expect(isClose(yaw, 0, tolerance: poseTolerance))
        #expect(isClose(result.roll, 0, tolerance: poseTolerance))
    }
}

@Test func rollRoundTripsAndLeavesTheOtherAxesAtZero() throws {
    let head = SyntheticHead()
    for angle in [Float(-60), -35, -12, 12, 35, 60] {
        let result = try pose(head.project(yaw: 0, pitch: 0, roll: angle))
        let yaw = try #require(result.yaw)
        #expect(isClose(result.roll, angle, tolerance: poseTolerance))
        #expect(isClose(yaw, 0, tolerance: poseTolerance))
        #expect(isClose(result.pitch, 0, tolerance: poseTolerance))
    }
}

@Test func pitchStaysMonotonicWhereASingleLandmarkModelWouldReverse() throws {
    // A nose-only pitch estimate saturates near 26 degrees and then runs
    // BACKWARDS, so a head tipped 40 degrees up reads the same as one tipped
    // 12 degrees up. The mouth term is what removes that, and this is the
    // assertion that would catch its removal.
    let head = SyntheticHead()
    var previous = -Float.greatestFiniteMagnitude
    for angle in stride(from: Float(0), through: 60, by: 5) {
        let result = try pose(head.project(yaw: 0, pitch: angle, roll: 0))
        #expect(result.pitch > previous)
        previous = result.pitch
    }
}

@Test func yawIsNotContaminatedByPitch() throws {
    // The classic monocular coupling bug: dividing the nose's horizontal offset
    // by a CONSTANT forward extent overstates yaw badly once the head is also
    // pitched, because looking up swings the nose further sideways for the same
    // turn. Computing pitch first and feeding it into yaw's denominator is what
    // removes it, and this is the assertion that would catch its return.
    let head = SyntheticHead()
    for pitch in [Float(-15), 0, 15, 30] {
        let result = try pose(head.project(yaw: 22, pitch: pitch, roll: 0))
        let yaw = try #require(result.yaw)
        #expect(isClose(yaw, 22, tolerance: poseTolerance))
        #expect(isClose(result.pitch, pitch, tolerance: poseTolerance))
    }
}

@Test func rollDoesNotLeakIntoYawOrPitch() throws {
    // If the de-roll were dropped, a tilted head would read as a turned one:
    // roll swings the nose sideways in the image exactly the way yaw does.
    let head = SyntheticHead()
    for roll in [Float(-40), -15, 15, 40] {
        let result = try pose(head.project(yaw: 0, pitch: 12, roll: roll))
        let yaw = try #require(result.yaw)
        #expect(isClose(yaw, 0, tolerance: poseTolerance))
        #expect(isClose(result.pitch, 12, tolerance: poseTolerance))
        #expect(isClose(result.roll, roll, tolerance: poseTolerance))
    }
}

@Test func combinedAttitudesRoundTrip() throws {
    let head = SyntheticHead()
    let cases: [(Float, Float, Float)] = [
        (18, 10, -12), (-25, -12, 20), (30, 25, 8), (-8, 18, -35), (5, -5, 5),
    ]
    for (expectedYaw, expectedPitch, expectedRoll) in cases {
        let result = try pose(head.project(yaw: expectedYaw, pitch: expectedPitch, roll: expectedRoll))
        let yaw = try #require(result.yaw)
        #expect(isClose(yaw, expectedYaw, tolerance: poseTolerance))
        #expect(isClose(result.pitch, expectedPitch, tolerance: poseTolerance))
        #expect(isClose(result.roll, expectedRoll, tolerance: poseTolerance))
    }
}

@Test func positiveYawPutsTheNoseTowardTheViewersRight() throws {
    // The sign convention, asserted against the raw projected coordinates as
    // well as the recovered angle, so a matching sign flip in both the forward
    // model and the estimator would not hide. The preview is mirrored, so the
    // subject's right IS the viewer's right, and a rightward turn moves the
    // nose to a larger x.
    let head = SyntheticHead()
    let projection = head.project(yaw: 25, pitch: 0, roll: 0)
    #expect(projection.nose.x > head.eyeMidpoint.x)
    let yaw = try #require(try pose(projection).yaw)
    #expect(yaw > 0)
}

@Test func positivePitchMeansLookingUp() throws {
    // Looking up lifts the nose toward the eye line: its drop below the eye
    // midpoint shrinks.
    let head = SyntheticHead()
    let level = head.project(yaw: 0, pitch: 0, roll: 0)
    let up = head.project(yaw: 0, pitch: 25, roll: 0)
    #expect(up.nose.y < level.nose.y)
    #expect(try pose(up).pitch > 0)
}

@Test func positiveRollPutsTheSubjectsRightEyeLower() throws {
    let head = SyntheticHead()
    let projection = head.project(yaw: 0, pitch: 0, roll: 20)
    #expect(projection.rightEye.y > projection.leftEye.y)   // y is DOWN
    #expect(try pose(projection).roll > 0)
}

@Test func headPoseIsUnchangedByTheCamerasAspectRatio() throws {
    let wide = Aspect(frameWidth: 1280, frameHeight: 720)
    var head = SyntheticHead()
    head.aspect = wide
    let result = try pose(head.project(yaw: 21, pitch: -9, roll: 13), aspect: wide)
    let yaw = try #require(result.yaw)
    #expect(isClose(yaw, 21, tolerance: poseTolerance))
    #expect(isClose(result.pitch, -9, tolerance: poseTolerance))
    #expect(isClose(result.roll, 13, tolerance: poseTolerance))
}

@Test func headPoseIsUnchangedByHowCloseTheUserSits() throws {
    var near = SyntheticHead()
    near.interocular = 0.30
    near.eyeMidpoint = vp(0.5, 0.45)
    var far = SyntheticHead()
    far.interocular = 0.06
    far.eyeMidpoint = vp(0.2, 0.25)
    let poseNear = try pose(near.project(yaw: 17, pitch: 11, roll: -6))
    let poseFar = try pose(far.project(yaw: 17, pitch: 11, roll: -6))
    #expect(isClose(try #require(poseNear.yaw), try #require(poseFar.yaw), tolerance: poseTolerance))
    #expect(isClose(poseNear.pitch, poseFar.pitch, tolerance: poseTolerance))
    #expect(isClose(poseNear.roll, poseFar.roll, tolerance: poseTolerance))
}

@Test func yawIsAbsentWhenPitchHidesTheCueItIsReadFrom() throws {
    // Looking far enough down swings the nose from "in front of the eyes" to
    // "directly below them", and a head turn stops moving it sideways at all.
    // Yaw is genuinely unobservable there; pitch and roll are not. Reporting a
    // yaw of 0 would say "facing the camera" about a head turned 20 degrees.
    let singularPitch = -Geometry.degrees(atan2(HeadPoseModel.default.noseProjection,
                                                HeadPoseModel.default.noseDrop))
    let result = try pose(SyntheticHead().project(yaw: 20, pitch: singularPitch, roll: 0))
    #expect(result.yaw == nil)
    #expect(isClose(result.pitch, singularPitch, tolerance: poseTolerance))
    #expect(isClose(result.roll, 0, tolerance: poseTolerance))
}

@Test func headPoseIsNilWhenTheEyeCentresCoincide() {
    // Two coincident eye centres mean the detector lost the face, not that the
    // head is perfectly frontal.
    #expect(HeadPoseEstimator.estimate(leftEye: vp(0.5, 0.4),
                                       rightEye: vp(0.5, 0.4),
                                       nose: vp(0.5, 0.5),
                                       mouth: vp(0.5, 0.56),
                                       aspect: .square) == nil)
}

@Test func headPoseIsNilWhenEveryLandmarkCollapsedOntoOnePoint() {
    #expect(HeadPoseEstimator.estimate(leftEye: vp(0.4, 0.4),
                                       rightEye: vp(0.6, 0.4),
                                       nose: vp(0.5, 0.4),
                                       mouth: vp(0.5, 0.4),
                                       aspect: .square) == nil)
}

@Test func headPoseFromAFaceFrameUsesPupilsNoseAndOuterLips() throws {
    let head = SyntheticHead()
    let frame = head.faceFrame(yaw: -19, pitch: 7, roll: 11)
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: FaceFixture.layout))
    let result = try #require(HeadPoseEstimator.estimate(face: landmarks, aspect: .square))
    #expect(isClose(try #require(result.yaw), -19, tolerance: poseTolerance))
    #expect(isClose(result.pitch, 7, tolerance: poseTolerance))
    #expect(isClose(result.roll, 11, tolerance: poseTolerance))
}

@Test func headPoseFromAFaceFrameIsNilWhenARequiredRegionIsMissing() throws {
    // No nose region means no monocular pose information at all. Absent, never
    // zero.
    var counts = FaceRegion.allCases.map { FaceFixture.layout.pointCount(of: $0) }
    counts[FaceRegion.nose.rawValue] = 0
    let layout = try #require(FaceLandmarkLayout(pointCounts: counts))
    var points: [VCTPoint] = []
    for region in FaceRegion.allCases {
        points += Array(repeating: vp(0.5, 0.5), count: layout.pointCount(of: region))
    }
    var frame = VCTFaceFrame()
    frame.points = points
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: layout))
    #expect(landmarks.nose == nil)
    #expect(HeadPoseEstimator.estimate(face: landmarks, aspect: .square) == nil)
}
