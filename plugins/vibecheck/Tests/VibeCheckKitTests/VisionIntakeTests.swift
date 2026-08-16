import Testing
import CoreGraphics
import Foundation
import VCKStubs
@testable import VibeCheckKit

// The join is the load-bearing new thing in the cutover. `BFRBDetector`
// needs a face, a hand and (for hair-pulling) a mask FROM THE SAME CAPTURE
// FRAME, and the bus makes no ordering or delivery promise across topics —
// events are ephemeral and a slow subscriber is dropped rather than
// buffered. So the failure this suite exists to exclude is evaluating this
// frame's fingertip against the previous frame's hair mask, which is a false
// positive every time a hand moves quickly.

@Test func aCompleteSetEmitsExactlyOnceWhenTheLastTopicArrives() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands])

    let face = try Fixtures.face(seq: 5, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                                 nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
        .serializedBytes() as Data
    let hands = try Fixtures.hands(seq: 5, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data

    #expect(await joiner.ingest(topic: VisionTopic.face.rawValue, payload: face) == nil)
    let frame = try #require(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: hands))
    #expect(frame.seq == 5)
    #expect(frame.fingertips.count == 1)
    #expect(frame.face != nil)

    let stats = await joiner.stats()
    #expect(stats.joined == 1)
    #expect(stats.lastSeq == 5)
}

@Test func topicsArrivingOutOfOrderStillJoin() async throws {
    // Nothing guarantees the provider publishes face before hands, or that
    // core delivers them in publication order across topics.
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands, .segmentation])

    let seg = try Fixtures.segmentation(seq: 9, cols: 2, rows: 2, allPerson: true).serializedBytes() as Data
    let hands = try Fixtures.hands(seq: 9, fingertips: [CGPoint(x: 0.5, y: 0.2)]).serializedBytes() as Data
    let face = try Fixtures.face(seq: 9, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                                 nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
        .serializedBytes() as Data

    #expect(await joiner.ingest(topic: VisionTopic.segmentation.rawValue, payload: seg) == nil)
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: hands) == nil)
    let frame = try #require(await joiner.ingest(topic: VisionTopic.face.rawValue, payload: face))
    #expect(frame.seq == 9)
    #expect(frame.segmentation != nil)
}

// THE assertion of this suite. A frame whose segmentation never arrived must
// be SKIPPED, not evaluated with the previous frame's hair data.
@Test func aFrameMissingARequiredTopicIsSkippedRatherThanEvaluatedWithStaleData() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands, .segmentation])

    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    func face(_ seq: UInt64) throws -> Data {
        try Fixtures.face(seq: seq, box: box, nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
            .serializedBytes()
    }
    func hands(_ seq: UInt64) throws -> Data {
        try Fixtures.hands(seq: seq, fingertips: [CGPoint(x: 0.5, y: 0.2)]).serializedBytes()
    }
    func seg(_ seq: UInt64) throws -> Data {
        try Fixtures.segmentation(seq: seq, cols: 2, rows: 2, allPerson: true).serializedBytes()
    }

    // Frame 1: complete.
    _ = await joiner.ingest(topic: VisionTopic.face.rawValue, payload: try face(1))
    _ = await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(1))
    let first = try #require(await joiner.ingest(topic: VisionTopic.segmentation.rawValue, payload: try seg(1)))
    #expect(first.segmentation != nil)

    // Frame 2: segmentation is dropped for a slow subscriber. Nothing may
    // come out — not even a frame carrying frame 1's mask.
    #expect(await joiner.ingest(topic: VisionTopic.face.rawValue, payload: try face(2)) == nil)
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(2)) == nil)

    // Frame 3: complete again. Emitting it must also retire frame 2, and
    // frame 2 must be counted as skipped rather than silently forgotten.
    _ = await joiner.ingest(topic: VisionTopic.face.rawValue, payload: try face(3))
    _ = await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(3))
    let third = try #require(await joiner.ingest(topic: VisionTopic.segmentation.rawValue, payload: try seg(3)))
    #expect(third.seq == 3)

    let stats = await joiner.stats()
    #expect(stats.joined == 2)
    #expect(stats.skipped == 1)
}

@Test func twoIncompleteFramesInFlightNeverLendEachOtherTheirParts() async throws {
    // THE join test. The suite above proves an incomplete set emits nothing,
    // but it cannot prove the parts are keyed by seq: its frame-2 and frame-3
    // fixtures carry identical coordinates, so a joiner that merged every
    // pending partial into one bucket would emit byte-identical output and
    // stay green.
    //
    // So: two frames in flight at once, with values that CANNOT be confused,
    // completed out of the order they arrived. If the join is by seq, frame 5
    // carries frame 5's fingertip and frame 5's mask. If it is not, frame 4's
    // parts leak in — which is precisely the "this frame's fingertip against
    // the previous frame's hair mask" false positive the join exists to stop.
    // Two topics required, which is the ordinary shape when hair-pulling is
    // off. That matters: it makes ONE part enough to complete a set, so a
    // borrowed part shows up as a frame emitted a beat too early rather than
    // as a value that has to survive dictionary ordering to be observed.
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands])

    let noseFour = CGPoint(x: 0.20, y: 0.20)
    let noseFive = CGPoint(x: 0.80, y: 0.80)
    func face(_ seq: UInt64, nose: CGPoint) throws -> Data {
        try Fixtures.face(seq: seq,
                          box: CGRect(x: nose.x - 0.1, y: nose.y - 0.15, width: 0.2, height: 0.3),
                          nose: nose,
                          mouth: CGPoint(x: nose.x, y: nose.y + 0.08)).serializedBytes()
    }

    // Frame 4's face arrives and waits — its hands never come.
    #expect(await joiner.ingest(topic: VisionTopic.face.rawValue,
                                payload: try face(4, nose: noseFour)) == nil)

    // Frame 5's hands arrive next. This is the assertion that carries the
    // test: `pending` holds exactly one partial right now, so a joiner that
    // reached for "the pending partial" instead of "the partial for THIS
    // seq" would find frame 4's face, consider frame 5 complete, and emit a
    // frame pairing frame 5's fingertip with frame 4's face. Nothing may
    // come out yet.
    #expect(await joiner.ingest(
        topic: VisionTopic.hands.rawValue,
        payload: try Fixtures.hands(seq: 5, fingertips: [CGPoint(x: 0.52, y: 0.18)]).serializedBytes()) == nil,
        "frame 5 is not complete — borrowing frame 4's face to finish it is the bug this guards")

    // Frame 5's own face completes it, and the anchors must be frame 5's.
    let emitted = try #require(await joiner.ingest(topic: VisionTopic.face.rawValue,
                                                   payload: try face(5, nose: noseFive)))
    #expect(emitted.seq == 5)
    // Tolerance because the wire carries `float`; the two candidate noses are
    // 0.6 apart, far outside any rounding.
    let nose = try #require(emitted.face?.nose)
    #expect(abs(nose.x - noseFive.x) < 0.01 && abs(nose.y - noseFive.y) < 0.01,
            "frame 5 must carry ITS OWN face, not the one still pending on frame 4")

    // Frame 4 was never completed: skipped, not emitted late and not quietly
    // absorbed into frame 5's join.
    let stats = await joiner.stats()
    #expect(stats.joined == 1)
    #expect(stats.skipped == 1)
}

@Test func theBufferIsBoundedAndCountsWhatItEvicts() async throws {
    // The bus drops slow subscribers rather than buffering without bound,
    // and a consumer that does the opposite has merely moved the leak. A
    // provider that publishes faces but never hands must cost a constant
    // amount of memory here.
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands])

    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    for seq in 1...200 {
        let face = try Fixtures.face(seq: UInt64(seq), box: box,
                                     nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
            .serializedBytes() as Data
        #expect(await joiner.ingest(topic: VisionTopic.face.rawValue, payload: face) == nil)
    }
    let stats = await joiner.stats()
    #expect(stats.joined == 0)
    #expect(stats.skipped == 200 - VisionFrameJoiner.maxPending)
}

@Test func aSequenceOlderThanTheLastEmittedIsRefused() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.hands])

    let ten = try Fixtures.hands(seq: 10, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data
    let nine = try Fixtures.hands(seq: 9, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: ten) != nil)
    // A straggler for an already-evaluated frame must not be re-evaluated:
    // it would double-count dwell for a moment that has already passed.
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: nine) == nil)
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: ten) == nil)
}

@Test func aTopicNobodyAskedForIsNotBuffered() async throws {
    // The provider publishes to every subscriber of a topic SOMEONE asked
    // for. Holding segmentation we never requested would grow `pending`
    // with sets that can never complete under our own rule.
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands])
    let seg = try Fixtures.segmentation(seq: 1, cols: 2, rows: 2, allPerson: true).serializedBytes() as Data
    #expect(await joiner.ingest(topic: VisionTopic.segmentation.rawValue, payload: seg) == nil)

    let face = try Fixtures.face(seq: 1, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                                 nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
        .serializedBytes() as Data
    let hands = try Fixtures.hands(seq: 1, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data
    _ = await joiner.ingest(topic: VisionTopic.face.rawValue, payload: face)
    let frame = try #require(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: hands))
    #expect(frame.segmentation == nil)
}

@Test func noRequiredTopicsMeansNothingCanEverComplete() async throws {
    // The empty-request state. `required.allSatisfy` over an empty set is
    // vacuously true, so without an explicit guard every single message
    // would "complete" a set and a switched-off detector would keep
    // detecting.
    let joiner = VisionFrameJoiner()
    let hands = try Fixtures.hands(seq: 1, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: hands) == nil)
    #expect(await joiner.stats().joined == 0)
}

@Test func anUndecodablePayloadIsDroppedAndDoesNotPoisonLaterFrames() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.hands])
    // Field 1 declared as a varint but truncated — not a valid HandsFrame.
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: Data([0x08])) == nil)
    let hands = try Fixtures.hands(seq: 1, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes() as Data
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: hands) != nil)
}

@Test func anUnknownTopicIsIgnored() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.hands])
    #expect(await joiner.ingest(topic: "vision.body_pose.v1", payload: Data()) == nil)
    #expect(await joiner.ingest(topic: "_core.demand.v1", payload: Data()) == nil)
}

@Test func statsReportTheSubscriptionRuleSoAMisconfiguredConsumerIsVisible() async throws {
    // "Subscribing without requesting yields nothing, and that must be
    // loud" — the provider logs it, and this is the readout on this side:
    // topics required with zero joined is the signature.
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.face, .hands])
    let stats = await joiner.stats()
    #expect(stats.requiredTopics == ["vision.face.v1", "vision.hands.v1"])
    #expect(stats.joined == 0)
    #expect(stats.lastSeq == nil)
}

// A provider restart is the other thing that looks like "an older sequence
// number", and it must NOT be refused: `Header.seq` is monotonic per
// provider, not globally, so a vision process that crashes and is respawned
// starts counting from the beginning. Refusing those on the straggler rule
// would wedge this join permanently — detection dead after any provider
// restart, and staying dead, with nothing in the log but silence.
@Test func aProviderRestartResetsTheJoinRatherThanWedgingIt() async throws {
    let joiner = VisionFrameJoiner()
    await joiner.setRequired([.hands])

    func hands(_ seq: UInt64) throws -> Data {
        try Fixtures.hands(seq: seq, fingertips: [CGPoint(x: 0.5, y: 0.5)]).serializedBytes()
    }

    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(5_000)) != nil)
    // A straggler one behind is still refused …
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(4_999)) == nil)
    // … but a jump back past the buffer depth is a restart, and detection
    // has to resume from it.
    let restarted = try #require(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(1)))
    #expect(restarted.seq == 1)
    #expect(await joiner.ingest(topic: VisionTopic.hands.rawValue, payload: try hands(2)) != nil)
}
