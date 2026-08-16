import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

@Test func levelShouldersReadZeroDegrees() throws {
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.60), 0.9),
    ]))
    let angle = try #require(BodySignals.shoulderAngleDegrees(body, aspect: .square))
    #expect(isClose(angle, 0, tolerance: angleTolerance))
}

@Test func aLoweredRightShoulderReadsPositive() throws {
    // Same sign convention as HeadPose.roll: positive means the SUBJECT's right
    // side is lower on screen. A consumer comparing head tilt against shoulder
    // tilt is otherwise comparing two opposite conventions.
    // dx = 0.2, dy = 0.1 -> atan2(0.1, 0.2) = 26.565 degrees.
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ]))
    let angle = try #require(BodySignals.shoulderAngleDegrees(body, aspect: .square))
    #expect(isClose(angle, 26.565051, tolerance: 1e-3))
}

@Test func aLoweredLeftShoulderReadsNegative() throws {
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.70), 0.9),
        .rightShoulder: (vp(0.60, 0.60), 0.9),
    ]))
    let angle = try #require(BodySignals.shoulderAngleDegrees(body, aspect: .square))
    #expect(isClose(angle, -26.565051, tolerance: 1e-3))
}

@Test func shoulderAngleIsCorrectedForTheCamerasAspectRatio() throws {
    // The same normalized offsets on a 2:1 frame describe a physically much
    // wider shoulder line, so the tilt is half as steep: atan2(0.1, 0.4).
    let wide = Aspect(frameWidth: 200, frameHeight: 100)
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ]))
    let angle = try #require(BodySignals.shoulderAngleDegrees(body, aspect: wide))
    #expect(isClose(angle, 14.036243, tolerance: 1e-3))
}

@Test func shoulderAngleDoesNotDependOnWhichShoulderIsReadFirst() throws {
    // A shoulder LINE has no head and tail, and folding into (-90, 90] is what
    // makes that true: reversing the vector adds 180 degrees, which the fold
    // removes. So the documented sign convention ("positive = the subject's
    // right shoulder is lower") is a property of the geometry rather than of
    // the traversal order, and swapping the two joints must change nothing.
    let asPublished = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ]))
    let swapped = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.60, 0.70), 0.9),
        .rightShoulder: (vp(0.40, 0.60), 0.9),
    ]))
    let a = try #require(BodySignals.shoulderAngleDegrees(asPublished, aspect: .square))
    let b = try #require(BodySignals.shoulderAngleDegrees(swapped, aspect: .square))
    #expect(isClose(a, b, tolerance: 1e-4))
    #expect(isClose(a, 26.565051, tolerance: 1e-3))
}

@Test func shoulderAngleStaysWithinNinetyDegreesOfHorizontal() throws {
    // The fold is load-bearing exactly here: a subject whose shoulders cross in
    // x (a body-pose frame that mislabelled the sides, or a user lying down)
    // produces a raw angle past 90 degrees, and an unfolded -153 would look
    // like a catastrophic lean instead of the 27-degree tilt it is.
    let crossed = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.60, 0.70), 0.9),
        .rightShoulder: (vp(0.40, 0.60), 0.9),
    ]))
    let angle = try #require(BodySignals.shoulderAngleDegrees(crossed, aspect: .square))
    #expect(angle > -90 && angle <= 90)
    #expect(isClose(angle, 26.565051, tolerance: 1e-3))
}

@Test func shoulderAngleIsAbsentWhenAJointIsBelowTheConfidenceGate() {
    // An undetected joint is still published, at whatever the model last
    // guessed. Those coordinates are fiction, and a "shoulder angle" derived
    // from them describes the back of a chair.
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.05),
    ]))
    #expect(BodySignals.shoulderAngleDegrees(body, aspect: .square) == nil)
}

@Test func shoulderAngleIsAbsentForAnEmptyBodyFrame() {
    // An empty joints array is the valid "no body detected" message.
    var frame = VCTBodyPoseFrame()
    frame.header = vheader()
    let body = BodyLandmarks(frame: frame)
    #expect(BodySignals.shoulderAngleDegrees(body, aspect: .square) == nil)
    #expect(BodySignals.headOverShoulders(body, aspect: .square) == nil)
}

@Test func shoulderAngleIsAbsentWhenBothShouldersLandOnTheSamePoint() {
    // A zero-length line has no tilt. Reporting 0 would be indistinguishable
    // from genuinely level shoulders.
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.50, 0.60), 0.9),
        .rightShoulder: (vp(0.50, 0.60), 0.9),
    ]))
    #expect(BodySignals.shoulderAngleDegrees(body, aspect: .square) == nil)
}

@Test func headOverShouldersMeasuresPerpendicularDistanceFromTheShoulderLine() throws {
    // Ears centred at (0.50, 0.30), shoulder line flat at y = 0.50: the head
    // sits 0.20 frame-heights above it.
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.50), 0.9),
        .rightShoulder: (vp(0.60, 0.50), 0.9),
        .leftEar: (vp(0.45, 0.30), 0.8),
        .rightEar: (vp(0.55, 0.30), 0.8),
    ]))
    let distance = try #require(BodySignals.headOverShoulders(body, aspect: .square))
    #expect(isClose(distance, 0.20, tolerance: lengthTolerance))
}

@Test func headOverShouldersDecreasesAsTheHeadSinksTowardTheShoulders() throws {
    // The direction that matters, and the one a consumer most easily gets
    // backwards: a webcam cannot see sagittal translation at all, so what
    // forward-head posture looks like from the front is the head DROPPING. The
    // signal therefore falls as posture worsens.
    func value(earY: Float) throws -> Float {
        let body = BodyLandmarks(frame: vbody([
            .leftShoulder: (vp(0.40, 0.50), 0.9),
            .rightShoulder: (vp(0.60, 0.50), 0.9),
            .leftEar: (vp(0.45, earY), 0.8),
            .rightEar: (vp(0.55, earY), 0.8),
        ]))
        return try #require(BodySignals.headOverShoulders(body, aspect: .square))
    }
    #expect(try value(earY: 0.25) > value(earY: 0.35))
    #expect(try value(earY: 0.35) > value(earY: 0.45))
}

@Test func headOverShouldersIgnoresShoulderTilt() throws {
    // Measured perpendicular to the shoulder line, so leaning does not read as
    // a posture change. Rotating the whole rig about the shoulder midpoint must
    // leave the value alone.
    let pivot = Vector2(x: 0.5, y: 0.5)
    func rotate(_ p: VCTPoint, by degrees: Float) -> VCTPoint {
        let c = cos(Geometry.radians(degrees))
        let s = sin(Geometry.radians(degrees))
        let dx = p.x - pivot.x
        let dy = p.y - pivot.y
        return vp(pivot.x + dx * c - dy * s, pivot.y + dx * s + dy * c)
    }
    let upright: [BodyJoint: VCTPoint] = [
        .leftShoulder: vp(0.40, 0.50),
        .rightShoulder: vp(0.60, 0.50),
        .leftEar: vp(0.45, 0.30),
        .rightEar: vp(0.55, 0.30),
    ]
    for tilt in [Float(0), 15, -25, 40] {
        var overrides: [BodyJoint: (VCTPoint, Float)] = [:]
        for (joint, point) in upright {
            overrides[joint] = (rotate(point, by: tilt), 0.9)
        }
        let body = BodyLandmarks(frame: vbody(overrides))
        let distance = try #require(BodySignals.headOverShoulders(body, aspect: .square))
        #expect(isClose(distance, 0.20, tolerance: 1e-4))
    }
}

@Test func headOverShouldersIsAbsentWhenOnlyOneEarIsVisible() {
    // A one-eared midpoint is offset by half a head width and nothing
    // downstream could tell. The nose is deliberately not a fallback either:
    // it swings with yaw, so a head-turn would read as a posture change.
    let body = BodyLandmarks(frame: vbody([
        .leftShoulder: (vp(0.40, 0.50), 0.9),
        .rightShoulder: (vp(0.60, 0.50), 0.9),
        .leftEar: (vp(0.45, 0.30), 0.8),
        .rightEar: (vp(0.55, 0.30), 0.05),
        .nose: (vp(0.50, 0.34), 0.99),
    ]))
    #expect(BodySignals.headOverShoulders(body, aspect: .square) == nil)
}

@Test func bodyLandmarksToleratesAShortJointArray() {
    // A provider that published fewer than 19 joints yields whatever it
    // genuinely contains, rather than the whole frame being rejected.
    var frame = VCTBodyPoseFrame()
    frame.joints = [vjoint(vp(0.5, 0.2), confidence: 0.9)]   // nose only
    let body = BodyLandmarks(frame: frame)
    #expect(body.point(.nose) != nil)
    #expect(body.point(.leftShoulder) == nil)
}

@Test func bodyJointIndicesMatchTheNormativeProtoOrder() {
    // These indices are defined by proto/topics/v1/vision.proto, not by Apple,
    // so unlike the face constellation they can be pinned here.
    #expect(BodyJoint.nose.rawValue == 0)
    #expect(BodyJoint.neck.rawValue == 5)
    #expect(BodyJoint.leftShoulder.rawValue == 6)
    #expect(BodyJoint.rightShoulder.rawValue == 7)
    #expect(BodyJoint.root.rawValue == 12)
    #expect(BodyJoint.rightAnkle.rawValue == 18)
    #expect(BodyJoint.allCases.count == 19)
}
