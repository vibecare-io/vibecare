import Foundation
import Testing
@testable import BlinkJumpKit

/// Records what reached the bus. An actor because `BusPublisher` is `Sendable`
/// and the requester calls it from its own isolation.
private actor RecordingPublisher: BusPublisher {
    struct Sent: Equatable {
        var topic: String
        var payload: Data
    }

    private(set) var sent: [Sent] = []
    private var failuresLeft = 0

    struct Wedged: Error {}

    func failNext(_ count: Int) { failuresLeft = count }

    func publish(topic: String, payload: Data) async throws {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw Wedged()
        }
        sent.append(Sent(topic: topic, payload: payload))
    }

    func topics() -> [[String]] {
        sent.map { VisionRequestIntent.topics(of: $0.payload) }
    }
}

private extension VisionRequestIntent {
    /// Reads the `topics` back out of an encoded request without the generated
    /// decoder — field 2, wire type 2. Keeps these tests asserting on bytes
    /// that actually went to the bus rather than on the requester's own copy.
    static func topics(of payload: Data) -> [String] {
        let bytes = Array(payload)
        var index = 0
        var topics: [String] = []
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { break }
            switch key & 0x7 {
            case 0:
                _ = varint()
            case 5:
                index += 4
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return topics }
                let slice = bytes[index..<index + Int(length)]
                index += Int(length)
                if key >> 3 == 2 { topics.append(String(decoding: slice, as: UTF8.self)) }
            default:
                return topics
            }
        }
        return topics
    }
}

@Test func nothingIsPublishedBeforeAHostExists() async {
    // `VCHost.publish` needs a live gRPC client, and routes (and therefore
    // everything they depend on) are built before `connect()` is ever called.
    let requester = VisionRequester(requester: "blink-jump")
    await requester.setPlayers(1)

    let snapshot = await requester.snapshot()
    #expect(snapshot.hostAttached == false)
    #expect(snapshot.assertions == 0)
}

@Test func connectingWithNobodyPlayingPublishesTheRetraction() async {
    // The camera must be off at rest. Staying silent instead would leave any
    // request from a previous run of this process live until its TTL expired.
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)

    let sent = await publisher.sent
    #expect(sent.count == 1)
    #expect(sent.first?.topic == VisionTopic.request)
    #expect(await publisher.topics() == [[]])
}

@Test func aPlayerOpeningTheGameAsksForSignalsAndClosingItReleasesThem() async {
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)

    await requester.setPlayers(1)
    #expect(await publisher.topics() == [[], [VisionTopic.signals, VisionTopic.face]],
            "signals are arithmetic, so asking for them without asking for the face model they are computed from yields ear_l absent on every frame — see VisionRequester.playingTopics")

    // A second tab is not a second request: only the crossing of zero changes
    // what the provider is being asked for.
    await requester.setPlayers(2)
    #expect(await publisher.sent.count == 2)

    await requester.setPlayers(1)
    #expect(await publisher.sent.count == 2)

    // The last tab closing is what turns the camera off. This is the demand
    // story's far end and the reason this plugin is not always-on.
    await requester.setPlayers(0)
    #expect(await publisher.topics() == [[], [VisionTopic.signals, VisionTopic.face], []])

    let snapshot = await requester.snapshot()
    #expect(snapshot.topics.isEmpty)
    #expect(snapshot.players == 0)
}

@Test func theIntentCarriesTheFrameRateAndTTL() async {
    let requester = VisionRequester(requester: "blink-jump", fps: 30)
    await requester.setPlayers(1)
    let intent = await requester.intent

    #expect(intent.requester == "blink-jump")
    #expect(intent.topics == [VisionTopic.signals, VisionTopic.face],
            "signals are arithmetic, so asking for them without asking for the face model they are computed from yields ear_l absent on every frame — see VisionRequester.playingTopics")
    #expect(intent.fps == 30)
    #expect(intent.ttlSeconds == 30, "the heartbeat is 10s, so the TTL has to be comfortably wider")
}

@Test func aDemandAnnouncementReassertsBecauseItMeansTheStreamReconnected() async {
    // Core announces demand for a plugin's own published topics on every
    // Subscribe, so this event IS the reconnect notice — and after a provider
    // restart there is no replay of anything published while it was down.
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)
    await requester.setPlayers(1)
    let before = await publisher.sent.count

    await requester.noteDemand(VCDemandReading(topic: VisionTopic.request, subscribers: 1))
    #expect(await publisher.sent.count == before + 1)
    #expect(await requester.snapshot().providerSubscribers == 1)

    // Demand for anything else is not ours to act on.
    await requester.noteDemand(VCDemandReading(topic: "vision.face.v1", subscribers: 4))
    #expect(await publisher.sent.count == before + 1)
    #expect(await requester.snapshot().providerSubscribers == 1)
}

@Test func zeroProviderSubscribersIsVisibleInTheReadout() async {
    // Subscribing without anything on the other end yields no events at all,
    // which is indistinguishable from a broken bus. This readout is the only
    // thing that tells them apart.
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)
    await requester.noteDemand(VCDemandReading(topic: VisionTopic.request, subscribers: 0))

    #expect(await requester.snapshot().providerSubscribers == 0)
}

@Test func aFailedPublishIsRecordedAndTheNextAssertionClearsIt() async {
    // A wedged core must not end the process, and must not end the game
    // either: the failure is recorded and the 10 s heartbeat retries.
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)

    await publisher.failNext(1)
    await requester.setPlayers(1)

    var snapshot = await requester.snapshot()
    #expect(snapshot.lastError != nil)
    #expect(snapshot.assertions == 1, "the failed publish must not count as an assertion")

    // Exactly what the heartbeat does.
    #expect(await requester.assertNow(reason: "heartbeat") == true)
    snapshot = await requester.snapshot()
    #expect(snapshot.lastError == nil)
    #expect(snapshot.topics == [VisionTopic.signals, VisionTopic.face])
}

@Test func shuttingDownRetractsTheRequest() async {
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump")
    await requester.attach(publisher: publisher)
    await requester.setPlayers(1)

    await requester.stop()
    #expect(await publisher.topics().last == [])

    // And nothing more goes out afterwards: the host is gone.
    #expect(await requester.assertNow(reason: "after stop") == false)
}

@Test func changingTheFrameRateOnlyRepublishesWhileSomeoneIsPlaying() async {
    let publisher = RecordingPublisher()
    let requester = VisionRequester(requester: "blink-jump", fps: 30)
    await requester.attach(publisher: publisher)

    await requester.setFPS(15)
    #expect(await publisher.sent.count == 1, "a retracted request has no rate worth announcing")

    await requester.setPlayers(1)
    await requester.setFPS(30)
    #expect(await publisher.sent.count == 3)
    #expect(await requester.snapshot().fps == 30)
}
