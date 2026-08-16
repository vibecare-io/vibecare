import Testing
import Foundation
import VCKStubs
@testable import PosturesKit

private let config = PostureConfig(
    enabled: true,
    shoulderAngleThreshold: 8,
    neckForwardThreshold: 0.18,
    dwell: 120,
    cooldown: 900
)

// MARK: - Absent is not zero
//
// The single most likely way to get a vision consumer wrong. A signals field
// is absent whenever the model that feeds it is not running, and a consumer
// that reads absent `shoulder_angle` as 0.0 sees perfectly level shoulders —
// so it reports good posture for a user who is not even in the room, and the
// bug is invisible because "good posture" is exactly what a working plugin
// looks like most of the time.

@Test func anEmptySignalsFrameDecodesToNoMeasurementsRatherThanZeros() {
    // The protobuf getters return 0 for an absent optional; the presence
    // accessors are the only thing that can tell the two apart.
    let sample = PostureSample.from(signals: VCTSignals())
    #expect(sample.shoulderAngle == nil)
    #expect(sample.neckForward == nil)
    #expect(sample.hasMeasurement == false)
}

@Test func absentSignalsScoreAsUnknownAndNotAsGood() {
    let sample = PostureSample.from(signals: VCTSignals())
    #expect(PostureScore.verdict(for: sample, config: config) == .unknown)
    // Stated explicitly, because `.good` is what a naive zero-default gives
    // and it is the failure this whole test file exists for.
    #expect(PostureScore.verdict(for: sample, config: config) != .good)
}

@Test func anExplicitZeroIsAMeasurementAndScoresAsGood() {
    // The other half of the rule: 0.0 that the provider actually sent means
    // perfectly level shoulders, and must not be mistaken for absence.
    var s = VCTSignals()
    s.shoulderAngle = 0
    let sample = PostureSample.from(signals: s)
    #expect(sample.shoulderAngle == 0)
    #expect(PostureScore.verdict(for: sample, config: config) == .good)
}

@Test func oneAbsentSignalDoesNotSuppressTheOtherPresentOne() {
    // A provider running body pose but not faces publishes shoulder_angle
    // with no neck_forward. That is a usable measurement, not a reason to
    // give up on the frame.
    var s = VCTSignals()
    s.shoulderAngle = 20
    let sample = PostureSample.from(signals: s)
    #expect(sample.neckForward == nil)
    #expect(PostureScore.verdict(for: sample, config: config) == .poor([.unevenShoulders]))
}

@Test func anAbsentSignalNeverContributesAFault() {
    var s = VCTSignals()
    s.neckForward = 0.5           // well over threshold
    let sample = PostureSample.from(signals: s)
    // shoulder_angle is absent, so `unevenShoulders` must not appear even
    // though a zero-defaulted 0.0 would be compared against the threshold.
    #expect(PostureScore.verdict(for: sample, config: config) == .poor([.forwardHead]))
}

// MARK: - Thresholds

@Test func shoulderTiltIsJudgedOnMagnitudeNotDirection() {
    for angle in [12.0, -12.0] {
        let sample = PostureSample(seq: 1, shoulderAngle: angle)
        #expect(PostureScore.verdict(for: sample, config: config) == .poor([.unevenShoulders]))
    }
    for angle in [7.9, -7.9] {
        let sample = PostureSample(seq: 1, shoulderAngle: angle)
        #expect(PostureScore.verdict(for: sample, config: config) == .good)
    }
}

@Test func forwardHeadIsOneSided() {
    // Heads crane forward. A head BEHIND the shoulders is unusual but it is
    // not the thing this plugin has an opinion about.
    #expect(PostureScore.verdict(for: PostureSample(seq: 1, neckForward: 0.4),
                                 config: config) == .poor([.forwardHead]))
    #expect(PostureScore.verdict(for: PostureSample(seq: 1, neckForward: -0.4),
                                 config: config) == .good)
}

@Test func exactlyAtTheThresholdIsNotYetAFault() {
    // Strict `>`, so a threshold the user typed is the largest value still
    // considered acceptable rather than the smallest one that nags.
    #expect(PostureScore.verdict(for: PostureSample(seq: 1, shoulderAngle: 8),
                                 config: config) == .good)
    #expect(PostureScore.verdict(for: PostureSample(seq: 1, neckForward: 0.18),
                                 config: config) == .good)
}

@Test func bothFaultsCanBeSetAtOnce() {
    let sample = PostureSample(seq: 1, shoulderAngle: -30, neckForward: 0.9)
    #expect(PostureScore.verdict(for: sample, config: config)
            == .poor([.unevenShoulders, .forwardHead]))
}

// MARK: - Body presence

@Test func anExplicitNoBodyBeatsAnyMeasurementThatArrivedWithIt() {
    let sample = PostureSample(seq: 1, shoulderAngle: 40, neckForward: 0.9, bodyDetected: false)
    #expect(PostureScore.verdict(for: sample, config: config) == .unknown)
}

@Test func anUnknownBodyPresenceIsNotTheSameAsNoBody() {
    // `nil` means no body-pose frame described this seq — a different
    // statement from "no body was there", and it must not veto a perfectly
    // good signals measurement.
    let sample = PostureSample(seq: 1, shoulderAngle: 40, bodyDetected: nil)
    #expect(PostureScore.verdict(for: sample, config: config) == .poor([.unevenShoulders]))
}

// MARK: - Body-pose decoding

private func joint(_ x: Float, _ y: Float, confidence: Float) -> VCTJoint {
    var p = VCTPoint()
    p.x = x
    p.y = y
    var j = VCTJoint()
    j.point = p
    j.confidence = confidence
    return j
}

/// A full 19-joint frame with everything low-confidence except the two
/// shoulders, which are placed as given. Matches the normative joint order in
/// `proto/topics/v1/vision.proto`.
private func bodyFrame(seq: UInt64 = 1,
                       left: (Float, Float), right: (Float, Float),
                       confidence: Float = 0.9) -> VCTBodyPoseFrame {
    var frame = VCTBodyPoseFrame()
    var header = VCTHeader()
    header.seq = seq
    frame.header = header
    frame.joints = (0..<19).map { _ in joint(0, 0, confidence: 0.05) }
    frame.joints[PostureJoint.leftShoulder] = joint(left.0, left.1, confidence: confidence)
    frame.joints[PostureJoint.rightShoulder] = joint(right.0, right.1, confidence: confidence)
    return frame
}

@Test func anEmptyJointsListIsTheValidNoBodyMessage() {
    // Per the topic contract, an empty frame is a published message meaning
    // "nothing detected" — not a malformed one.
    let reading = BodyPoseReading(VCTBodyPoseFrame())
    #expect(reading.bodyDetected == false)
    #expect(reading.shoulderAngle == nil)
}

@Test func joinsPresentButAllLowConfidenceAlsoMeansNoBody() {
    var frame = VCTBodyPoseFrame()
    frame.joints = (0..<19).map { _ in joint(0.5, 0.5, confidence: 0.05) }
    #expect(BodyPoseReading(frame).bodyDetected == false)
}

@Test func levelShouldersDeriveToZeroDegrees() {
    let reading = BodyPoseReading(bodyFrame(left: (0.4, 0.5), right: (0.6, 0.5)))
    #expect(reading.bodyDetected)
    #expect(reading.shoulderAngle == 0)
}

@Test func viewerSpaceYPointsDownSoALowerRightShoulderIsPositive() {
    let reading = BodyPoseReading(bodyFrame(left: (0.4, 0.4), right: (0.6, 0.6)))
    #expect(abs((reading.shoulderAngle ?? 0) - 45) < 0.001)
}

@Test func lowConfidenceShouldersYieldNoAngleRatherThanAGuess() {
    let reading = BodyPoseReading(bodyFrame(left: (0.4, 0.4), right: (0.6, 0.6), confidence: 0.2))
    #expect(reading.shoulderAngle == nil)
    // The frame still says a body is there only if some OTHER joint is
    // confident; here nothing is, so it is honestly reported as absent.
    #expect(reading.bodyDetected == false)
}

@Test func theShoulderLineIsUndirectedSoTheAngleFolds() {
    // Which endpoint the contract calls "left" is a labelling choice. Swap
    // them and the physical tilt is identical — a 175° reading would mean the
    // same thing as -5° while reading as catastrophic to any threshold test.
    let a = BodyPoseReading(bodyFrame(left: (0.4, 0.4), right: (0.6, 0.5))).shoulderAngle
    let b = BodyPoseReading(bodyFrame(left: (0.6, 0.5), right: (0.4, 0.4))).shoulderAngle
    #expect(a != nil && b != nil)
    #expect(abs(abs(a!) - abs(b!)) < 0.001)
    #expect(abs(a!) < 90 && abs(b!) < 90)
}

@Test func coincidentShouldersAreNotAMeasurement() {
    #expect(BodyPoseReading(bodyFrame(left: (0.5, 0.5), right: (0.5, 0.5))).shoulderAngle == nil)
}

@Test func aTruncatedJointsListDoesNotCrash() {
    // Nothing in a plugin may trap on a malformed payload; a provider on an
    // older contract is a bad message, not a reason to be charged a failed
    // start.
    var frame = VCTBodyPoseFrame()
    frame.joints = (0..<5).map { _ in joint(0.5, 0.5, confidence: 0.9) }
    #expect(BodyPoseReading(frame).shoulderAngle == nil)
    #expect(BodyPoseReading(frame).bodyDetected)
}

// MARK: - Merging the two topics

@Test func signalsAndBodyPoseFromOneFrameMerge() {
    var tracker = PostureTracker()
    var s = VCTSignals()
    var header = VCTHeader()
    header.seq = 7
    s.header = header
    s.shoulderAngle = 3
    s.neckForward = 0.4

    _ = tracker.ingest(bodyPose: BodyPoseReading(bodyFrame(seq: 7, left: (0.4, 0.5), right: (0.6, 0.5))))
    let merged = tracker.ingest(signals: PostureSample.from(signals: s))
    #expect(merged.seq == 7)
    #expect(merged.shoulderAngle == 3)      // signals win over the derivation
    // The wire type is `float`, so the widened `Double` is 0.4 to within
    // Float's precision and not exactly it. Compared with a tolerance rather
    // than pinned to 0.4000000059604645, which would encode this build's
    // rounding into the test.
    #expect(abs((merged.neckForward ?? 0) - 0.4) < 1e-6)
    #expect(merged.bodyDetected == true)
}

@Test func aStaleContributionIsTreatedAsAbsentNotAsUsable() {
    // Carrying a measurement forward from an earlier frame would manufacture
    // data the provider never produced — the same failure as reading absent
    // as zero, one step removed.
    var tracker = PostureTracker()
    var old = VCTSignals()
    var header = VCTHeader()
    header.seq = 7
    old.header = header
    old.neckForward = 0.9
    _ = tracker.ingest(signals: PostureSample.from(signals: old))

    let merged = tracker.ingest(bodyPose: BodyPoseReading(bodyFrame(seq: 8, left: (0.4, 0.5), right: (0.6, 0.5))))
    #expect(merged.seq == 8)
    #expect(merged.neckForward == nil)
    #expect(merged.shoulderAngle == 0)      // from the fresh body-pose frame
}

@Test func bodyPoseAloneStillProducesAUsableShoulderAngle() {
    // The §4.4 override ladder taken one rung down: a provider publishing
    // joints but no signals must not leave this plugin reporting "unknown"
    // forever.
    var tracker = PostureTracker()
    let merged = tracker.ingest(bodyPose: BodyPoseReading(bodyFrame(left: (0.4, 0.35), right: (0.6, 0.6))))
    #expect(merged.shoulderAngle != nil)
    #expect(PostureScore.verdict(for: merged, config: config) == .poor([.unevenShoulders]))
}
