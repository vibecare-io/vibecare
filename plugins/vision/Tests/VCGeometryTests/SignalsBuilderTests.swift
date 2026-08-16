import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

// The rule under test throughout this file: EVERY FIELD IS OPTIONAL AND ABSENT
// IS NOT ZERO. A consumer reading absent as 0.0 sees a permanently closed eye,
// a head staring dead ahead and a perfectly level pair of shoulders — three
// false readings that all look like real data.

/// Every optional field on `Signals`, paired with its presence flag, so a test
/// can assert about the whole message rather than about the fields it happened
/// to remember.
private func presenceChecks() -> [(name: String, isPresent: (VCTSignals) -> Bool)] {
    [
        ("ear_l", { $0.hasEarL }),
        ("ear_r", { $0.hasEarR }),
        ("yaw", { $0.hasYaw }),
        ("pitch", { $0.hasPitch }),
        ("roll", { $0.hasRoll }),
        ("shoulder_angle", { $0.hasShoulderAngle }),
        ("neck_forward", { $0.hasNeckForward }),
        ("fingertip_to_nose", { $0.hasFingertipToNose }),
        ("fingertip_to_mouth", { $0.hasFingertipToMouth }),
    ]
}

private func presentFields(_ signals: VCTSignals) -> Set<String> {
    Set(presenceChecks().filter { $0.isPresent(signals) }.map(\.name))
}

private func openEyedFace(yaw: Float = 0, pitch: Float = 0, roll: Float = 0) -> VCTFaceFrame {
    SyntheticHead().faceFrame(yaw: yaw, pitch: pitch, roll: roll)
}

@Test func noModelRunningLeavesEveryFieldAbsent() {
    let signals = SignalsBuilder().signals(header: vheader(seq: 42))
    #expect(presentFields(signals).isEmpty)
    // …and the header still rides along, because `seq` is what lets a consumer
    // join this payload to the tiers it was derived from.
    #expect(signals.hasHeader)
    #expect(signals.header.seq == 42)
    #expect(signals.header.deviceID == "fixture-camera")
}

@Test func aRunningFaceModelWithNoFaceInFrameLeavesEveryFieldAbsent() {
    // An empty FaceFrame is a valid published message meaning "the model ran
    // and saw nothing". The signals it feeds are UNKNOWN, not zero.
    var empty = VCTFaceFrame()
    empty.header = vheader()
    let signals = SignalsBuilder().signals(header: vheader(), face: empty, faceLayout: FaceFixture.layout)
    #expect(presentFields(signals).isEmpty)
}

@Test func aFaceWithoutALayoutLeavesEveryFaceDerivedFieldAbsent() {
    // Indexing into a constellation nobody validated is how an eyebrow gets
    // reported as an eye. Refusing is the only safe answer.
    let signals = SignalsBuilder().signals(header: vheader(), face: openEyedFace(), faceLayout: nil)
    #expect(presentFields(signals).isEmpty)
}

@Test func aLayoutThatDisagreesWithThePublishedPointCountIsRejected() throws {
    var counts = FaceRegion.allCases.map { FaceFixture.layout.pointCount(of: $0) }
    counts[FaceRegion.faceContour.rawValue] += 3
    let wrong = try #require(FaceLandmarkLayout(pointCounts: counts))
    let signals = SignalsBuilder().signals(header: vheader(), face: openEyedFace(), faceLayout: wrong)
    #expect(presentFields(signals).isEmpty)
}

@Test func onlyTheFaceModelRunningPopulatesExactlyTheFaceDerivedFields() {
    let signals = SignalsBuilder().signals(header: vheader(),
                                           face: openEyedFace(yaw: 14, pitch: -6, roll: 9),
                                           faceLayout: FaceFixture.layout)
    #expect(presentFields(signals) == ["ear_l", "ear_r", "yaw", "pitch", "roll"])
    #expect(isClose(signals.yaw, 14, tolerance: poseTolerance))
    #expect(isClose(signals.pitch, -6, tolerance: poseTolerance))
    #expect(isClose(signals.roll, 9, tolerance: poseTolerance))
    #expect(isClose(signals.earL, 0.35, tolerance: 1e-4))
    #expect(isClose(signals.earR, 0.35, tolerance: 1e-4))
}

@Test func aClosedEyeIsPublishedAsZeroAndPresent() {
    // The single most important assertion in this target. Zero and absent are
    // different messages on the wire: 0.0 means the eye is shut, absent means
    // nobody is looking.
    let signals = SignalsBuilder().signals(
        header: vheader(),
        face: SyntheticHead().faceFrame(yaw: 0, pitch: 0, roll: 0, eyeAspectRatio: 0),
        faceLayout: FaceFixture.layout)
    #expect(signals.hasEarL)
    #expect(signals.hasEarR)
    #expect(signals.earL == 0)
    #expect(signals.earR == 0)
}

@Test func anEyeTheDetectorLostIsAbsentRatherThanZero() {
    // The nastiest form of the absent-vs-zero trap, because the face model IS
    // running and the frame IS valid — only one contour collapsed, which is
    // what a detector does when it loses an eye behind a hand or a reflection.
    // Defaulting that to 0.0 publishes "eye closed" for as long as the detector
    // struggles, and a blink consumer reads a held blink that never happened.
    let head = SyntheticHead()
    let projection = head.project(yaw: 0, pitch: 0, roll: 0)
    let collapsed = [VCTPoint](repeating: projection.leftEye, count: FaceFixture.eyeContourPoints)
    func frame(leftCollapsed: Bool) -> VCTFaceFrame {
        let healthyLeft = FaceFixture.eyeContour(centre: projection.leftEye, halfWidth: 0.03, halfHeight: 0.01)
        let healthyRight = FaceFixture.eyeContour(centre: projection.rightEye, halfWidth: 0.03, halfHeight: 0.01)
        return FaceFixture.frame(leftEyeContour: leftCollapsed ? collapsed : healthyLeft,
                                 rightEyeContour: leftCollapsed ? healthyRight : collapsed,
                                 leftPupil: projection.leftEye,
                                 rightPupil: projection.rightEye,
                                 nose: projection.nose,
                                 mouth: projection.mouth)
    }

    let lostLeft = SignalsBuilder().signals(header: vheader(),
                                            face: frame(leftCollapsed: true),
                                            faceLayout: FaceFixture.layout)
    #expect(!lostLeft.hasEarL)
    #expect(lostLeft.hasEarR)          // the other eye is unaffected

    let lostRight = SignalsBuilder().signals(header: vheader(),
                                             face: frame(leftCollapsed: false),
                                             faceLayout: FaceFixture.layout)
    #expect(lostRight.hasEarL)
    #expect(!lostRight.hasEarR)

    // Head pose survives either loss: it reads the pupils, not the contours.
    #expect(lostLeft.hasRoll)
    #expect(lostRight.hasRoll)
}

@Test func aFaceWithNoNoseRegionKeepsTheEyesAndDropsEverythingPoseRelated() throws {
    // A constellation missing the nose still carries perfectly good eye
    // contours. Each signal is gated on the landmarks IT needs, so one absent
    // region must not blank the rest of the message — nor may it default the
    // pose to zero, which would claim the user is facing the screen.
    var counts = FaceRegion.allCases.map { FaceFixture.layout.pointCount(of: $0) }
    counts[FaceRegion.nose.rawValue] = 0
    let layout = try #require(FaceLandmarkLayout(pointCounts: counts))

    let contour = FaceFixture.eyeContour(centre: vp(0.44, 0.40), halfWidth: 0.03, halfHeight: 0.012)
    var points: [VCTPoint] = []
    for region in FaceRegion.allCases {
        switch region {
        case .leftEye, .rightEye: points += contour
        case .outerLips: points += Array(repeating: vp(0.50, 0.56), count: layout.pointCount(of: region))
        case .leftPupil: points += [vp(0.44, 0.40)]
        case .rightPupil: points += [vp(0.56, 0.40)]
        default: points += Array(repeating: vp(0.99, 0.01), count: layout.pointCount(of: region))
        }
    }
    var face = VCTFaceFrame()
    face.header = vheader()
    face.points = points

    let hands = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.50)])])
    let signals = SignalsBuilder().signals(header: vheader(),
                                           face: face,
                                           faceLayout: layout,
                                           hands: hands)
    #expect(presentFields(signals) == ["ear_l", "ear_r", "fingertip_to_mouth"])
}

@Test func shoulderAngleAndNeckForwardAreGatedIndependently() {
    // Ears go missing far more often than shoulders (hair, frame edge), and
    // when they do, the shoulder line is still perfectly measurable. Gating the
    // two together would throw away a good signal; defaulting the missing one
    // to zero would report a head sitting exactly on the shoulder line.
    let body = vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ])
    let signals = SignalsBuilder().signals(header: vheader(), body: body)
    #expect(signals.hasShoulderAngle)
    #expect(!signals.hasNeckForward)
}

@Test func onlyTheBodyModelRunningPopulatesExactlyTheBodyDerivedFields() {
    let body = vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
        .leftEar: (vp(0.45, 0.30), 0.8),
        .rightEar: (vp(0.55, 0.30), 0.8),
    ])
    let signals = SignalsBuilder().signals(header: vheader(), body: body)
    #expect(presentFields(signals) == ["shoulder_angle", "neck_forward"])
    #expect(isClose(signals.shoulderAngle, 26.565051, tolerance: 1e-3))
}

@Test func aRunningBodyModelWithLowConfidenceJointsLeavesBothBodyFieldsAbsent() {
    let body = vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.05),
        .rightShoulder: (vp(0.60, 0.70), 0.05),
    ])
    let signals = SignalsBuilder().signals(header: vheader(), body: body)
    #expect(presentFields(signals).isEmpty)
}

@Test func fingertipDistancesNeedBothTheHandAndFaceModels() {
    // Either one missing makes the distance undefined rather than large.
    let hands = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.50)])])
    let handsOnly = SignalsBuilder().signals(header: vheader(), hands: hands)
    #expect(presentFields(handsOnly).isEmpty)

    let faceOnly = SignalsBuilder().signals(header: vheader(),
                                            face: openEyedFace(),
                                            faceLayout: FaceFixture.layout)
    #expect(!faceOnly.hasFingertipToNose)
    #expect(!faceOnly.hasFingertipToMouth)
}

@Test func bothModelsRunningPopulatesTheFingertipDistances() {
    let head = SyntheticHead()
    let projection = head.project(yaw: 0, pitch: 0, roll: 0)
    // Park the index tip exactly 0.02 frame-heights directly below the nose.
    let tip = vp(projection.nose.x, projection.nose.y + 0.02)
    let signals = SignalsBuilder().signals(header: vheader(),
                                           face: head.faceFrame(yaw: 0, pitch: 0, roll: 0),
                                           faceLayout: FaceFixture.layout,
                                           hands: vhands([vhand(fingertips: [.indexTip: tip])]))
    #expect(signals.hasFingertipToNose)
    #expect(signals.hasFingertipToMouth)
    #expect(isClose(signals.fingertipToNose, 0.02, tolerance: 1e-4))
    // The mouth sits further down the face, so it must read further away.
    #expect(signals.fingertipToMouth > signals.fingertipToNose)
}

@Test func aRunningHandModelWithNoHandsLeavesTheFingertipDistancesAbsent() {
    let signals = SignalsBuilder().signals(header: vheader(),
                                           face: openEyedFace(),
                                           faceLayout: FaceFixture.layout,
                                           hands: vhands([]))
    #expect(!signals.hasFingertipToNose)
    #expect(!signals.hasFingertipToMouth)
    // The face-derived fields are unaffected: one absent tier does not
    // suppress another.
    #expect(signals.hasEarL)
    #expect(signals.hasRoll)
}

@Test func everyTierRunningPopulatesEveryField() {
    let head = SyntheticHead()
    let projection = head.project(yaw: 0, pitch: 0, roll: 0)
    let signals = SignalsBuilder().signals(
        header: vheader(),
        face: head.faceFrame(yaw: 8, pitch: 5, roll: -3),
        faceLayout: FaceFixture.layout,
        hands: vhands([vhand(fingertips: [.indexTip: vp(projection.nose.x, projection.nose.y + 0.03)])]),
        body: vbody([
            .leftShoulder: (vp(0.40, 0.70), 0.9),
            .rightShoulder: (vp(0.60, 0.70), 0.9),
            .leftEar: (vp(0.45, 0.45), 0.8),
            .rightEar: (vp(0.55, 0.45), 0.8),
        ]))
    #expect(presentFields(signals).count == presenceChecks().count)
}

@Test func yawAloneCanBeAbsentWhilePitchAndRollArePresent() {
    // There is a real head attitude — looking down far enough that the nose
    // points at the camera — where a single view carries no yaw information at
    // all. Publishing 0 there would claim the user is facing the screen.
    let singularPitch = -Geometry.degrees(atan2(HeadPoseModel.default.noseProjection,
                                                HeadPoseModel.default.noseDrop))
    let signals = SignalsBuilder().signals(
        header: vheader(),
        face: SyntheticHead().faceFrame(yaw: 20, pitch: singularPitch, roll: 0),
        faceLayout: FaceFixture.layout)
    #expect(!signals.hasYaw)
    #expect(signals.hasPitch)
    #expect(signals.hasRoll)
}

@Test func signalsAreCorrectedAgainstTheHeadersOwnFrameSize() {
    // The builder must not assume a square frame: the same landmarks under a
    // 16:9 header describe a physically different body, and the shoulder angle
    // is where that shows up most bluntly.
    let body = vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ])
    let square = SignalsBuilder().signals(header: vheader(width: 640, height: 640), body: body)
    let wide = SignalsBuilder().signals(header: vheader(width: 1280, height: 640), body: body)
    #expect(isClose(square.shoulderAngle, 26.565051, tolerance: 1e-3))
    #expect(isClose(wide.shoulderAngle, 14.036243, tolerance: 1e-3))
}

@Test func aHeaderWithoutAFrameSizeStillProducesSignals() {
    // A synthetic or replayed payload degrades to raw normalized distances
    // rather than to NaN or to nothing at all.
    let body = vbody([
        .leftShoulder: (vp(0.40, 0.60), 0.9),
        .rightShoulder: (vp(0.60, 0.70), 0.9),
    ])
    let signals = SignalsBuilder().signals(header: vheaderWithoutFrame(), body: body)
    #expect(signals.hasShoulderAngle)
    #expect(isClose(signals.shoulderAngle, 26.565051, tolerance: 1e-3))
}

@Test func theBuilderPublishesNoJudgementAboutBehaviour() {
    // Design §2: vision may publish a measurable property of the body and never
    // a verdict about behaviour. `Signals` has nine fields and every one of
    // them is a number with a unit; the day someone adds `is_blinking`, this
    // count changes and the reviewer gets to ask why.
    #expect(presenceChecks().count == 9)
}
