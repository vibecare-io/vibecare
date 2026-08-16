import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

@Test func handJointIndicesMatchTheNormativeProtoOrder() {
    #expect(HandJoint.wrist.rawValue == 0)
    #expect(HandJoint.thumbTip.rawValue == 4)
    #expect(HandJoint.indexTip.rawValue == 8)
    #expect(HandJoint.middleTip.rawValue == 12)
    #expect(HandJoint.ringTip.rawValue == 16)
    #expect(HandJoint.littleTip.rawValue == 20)
    #expect(HandJoint.allCases.count == 21)
    #expect(HandJoint.fingertips.count == 5)
}

@Test func minimumFingertipDistanceTakesTheNearestTip() throws {
    // Nose at (0.50, 0.40). The index tip sits 0.03 below it, the thumb 0.12
    // away; the answer is the index tip's 0.03.
    let hands = vhands([vhand(fingertips: [
        .indexTip: vp(0.50, 0.43),
        .thumbTip: vp(0.50, 0.52),
    ])])
    let d = try #require(HandSignals.minimumFingertipDistance(from: hands, to: vp(0.50, 0.40), aspect: .square))
    #expect(isClose(d, 0.03, tolerance: lengthTolerance))
}

@Test func minimumFingertipDistanceSearchesEveryHand() throws {
    // Order on HandsFrame is by descending confidence, never by handedness, so
    // reading only hands[0] would silently miss the hand that is actually near
    // the face.
    let far = vhand(fingertips: [.indexTip: vp(0.10, 0.90)], confidence: 0.95)
    let near = vhand(fingertips: [.indexTip: vp(0.50, 0.45)], confidence: 0.60)
    let d = try #require(HandSignals.minimumFingertipDistance(from: vhands([far, near]),
                                                              to: vp(0.50, 0.40),
                                                              aspect: .square))
    #expect(isClose(d, 0.05, tolerance: lengthTolerance))
}

@Test func minimumFingertipDistanceIsCorrectedForTheCamerasAspectRatio() throws {
    // 0.04 of normalized x on a 2:1 frame is 0.08 frame-heights.
    let wide = Aspect(frameWidth: 200, frameHeight: 100)
    let hands = vhands([vhand(fingertips: [.indexTip: vp(0.54, 0.40)])])
    let d = try #require(HandSignals.minimumFingertipDistance(from: hands, to: vp(0.50, 0.40), aspect: wide))
    #expect(isClose(d, 0.08, tolerance: lengthTolerance))
}

@Test func aLowConfidenceFingertipIsExcluded() throws {
    // A fingertip occluded behind the palm still has coordinates and they are
    // fiction. Trusting them puts a "nose contact" wherever the model last
    // guessed.
    let hands = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.41),
                                           .thumbTip: vp(0.50, 0.50)],
                              confidence: 0.9,
                              jointConfidence: [.indexTip: 0.05])])
    let d = try #require(HandSignals.minimumFingertipDistance(from: hands, to: vp(0.50, 0.40), aspect: .square))
    #expect(isClose(d, 0.10, tolerance: lengthTolerance))   // the thumb, not the index
}

@Test func anEmptyJointConfidenceArrayFallsBackToTheHandsOwnConfidence() {
    // Empty means UNKNOWN, not zero. Discarding every joint because per-joint
    // confidence was not reported would silently disable the signal against any
    // provider that does not populate it.
    let confident = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.43)], confidence: 0.9)])
    #expect(HandSignals.minimumFingertipDistance(from: confident, to: vp(0.50, 0.40), aspect: .square) != nil)

    let unsure = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.43)], confidence: 0.05)])
    #expect(HandSignals.minimumFingertipDistance(from: unsure, to: vp(0.50, 0.40), aspect: .square) == nil)
}

@Test func minimumFingertipDistanceIsAbsentWhenNoHandsAreInFrame() {
    // An empty HandsFrame is the valid "the model ran and saw no hands"
    // message. The minimum of an empty set is not a large number, it is
    // undefined — a consumer reading absence as "hands are far away" would be
    // right by accident today and wrong the moment a frame drops mid-gesture.
    #expect(HandSignals.minimumFingertipDistance(from: vhands([]),
                                                 to: vp(0.50, 0.40),
                                                 aspect: .square) == nil)
}

@Test func minimumFingertipDistanceIsAbsentWhenEveryTipFailsTheGate() {
    let hands = vhands([vhand(fingertips: [.indexTip: vp(0.50, 0.41)],
                              confidence: 0.9,
                              jointConfidence: [.thumbTip: 0.0, .indexTip: 0.0, .middleTip: 0.0,
                                                .ringTip: 0.0, .littleTip: 0.0])])
    #expect(HandSignals.minimumFingertipDistance(from: hands, to: vp(0.50, 0.40), aspect: .square) == nil)
}

@Test func handLandmarksToleratesAShortJointArray() {
    var hand = VCTHand()
    hand.confidence = 0.9
    hand.joints = [vp(0.5, 0.5)]   // wrist only
    let landmarks = HandLandmarks(hand: hand)
    #expect(landmarks.point(.wrist) != nil)
    #expect(landmarks.point(.indexTip) == nil)
    #expect(landmarks.fingertips.isEmpty)
}

@Test func theShippedConfidenceGateIsUnchangedFromTheVibecheckExtractor() {
    // Moving capture into the provider must not silently retune detection: the
    // BFRB detector has shipped against a 0.3 fingertip gate since day one.
    #expect(HandLandmarks.defaultMinimumConfidence == 0.3)
}
