import Testing
import Foundation
import VCKStubs
import VCPluginSDK
@testable import VibeCheckKit

// `vision.request.v1` is the whole point of the redesign: demand refcounting
// already closes the camera when nothing subscribes, but it cannot tell a
// user who switched detection off from a plugin that is merely idle — the
// process stays up and subscribed either way, so the LED stays on. These
// tests are about the one message that closes that gap, and the assertion
// that matters most is `disablingDetectionPublishesAnEmptyTopicList`.

private actor SpyHost: AlertHost {
    private(set) var published: [(topic: String, payload: Data)] = []
    private(set) var failNext = false

    func alert(_ a: VCAlert) async throws {}

    func publish(topic: String, payload: Data) async throws {
        if failNext {
            failNext = false
            throw VCHostError.notConnected
        }
        published.append((topic, payload))
    }

    func setFailNext() { failNext = true }

    func requests() throws -> [VCTRequest] {
        try published
            .filter { $0.topic == VisionRequest.topic }
            .map { try VCTRequest(serializedBytes: $0.payload) }
    }
}

private func config(enabled: Bool, behaviors: [BFRBBehavior]) -> VibeCheckConfig {
    var c = VibeCheckConfig.default
    c.enabled = enabled
    c.enabledBehaviors = behaviors.map(\.rawValue)
    return c
}

// MARK: - The pure topic rule

@Test func topicsAreTheUnionOfWhatTheEnabledBehavioursNeed() {
    #expect(VisionRequest.topics(for: config(enabled: true, behaviors: [.nailBiting]))
            == [.face, .hands])
    #expect(VisionRequest.topics(for: config(enabled: true, behaviors: [.nailBiting, .hairPulling]))
            == [.face, .hands, .segmentation])
    #expect(VisionRequest.topics(for: config(enabled: true, behaviors: BFRBBehavior.allCases))
            == [.face, .hands, .segmentation])
}

@Test func anythingThatMeansNotDetectingAsksForNothing() {
    // Two switches produce the same request, because they mean the same
    // thing to the provider: the master toggle off, and the master toggle on
    // with every behaviour unticked.
    #expect(VisionRequest.topics(for: config(enabled: false, behaviors: BFRBBehavior.allCases)).isEmpty)
    #expect(VisionRequest.topics(for: config(enabled: true, behaviors: [])).isEmpty)
}

@Test func onlyWantingNailBitingDoesNotPayForSegmentation() {
    // The cost claim of the whole tiering: one Vision request per topic, so
    // an unrequested topic is a model that is never constructed.
    #expect(VisionRequest.topics(for: config(enabled: true, behaviors: [.nailBiting, .nosePicking]))
            .contains(.segmentation) == false)
}

// MARK: - What actually goes on the wire

@Test func enablingDetectionPublishesADeclaredRequestWithTheAgreedFpsAndTtl() async throws {
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    let host = SpyHost()
    await request.attach(host: host)

    await request.configChanged(config(enabled: true, behaviors: [.nailBiting, .hairPulling]))

    let requests = try await host.requests()
    #expect(requests.count == 1)
    let r = try #require(requests.first)
    #expect(r.requester == "vibecheck")
    #expect(r.topics == ["vision.face.v1", "vision.hands.v1", "vision.segmentation.v1"])
    #expect(r.fps == 15)
    #expect(r.ttlS == 30)
    // The topic itself must be the one the manifest declares in `publishes`
    // — an undeclared topic is a logged error and a DROPPED message, which
    // here would silently mean the provider never runs the model we need.
    #expect(await host.published.map(\.topic) == ["vision.request.v1"])
}

// The assertion this whole file exists for.
@Test func disablingDetectionPublishesAnEmptyTopicList() async throws {
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    let host = SpyHost()
    await request.attach(host: host)

    await request.configChanged(config(enabled: true, behaviors: BFRBBehavior.allCases))
    await request.configChanged(config(enabled: false, behaviors: BFRBBehavior.allCases))

    let requests = try await host.requests()
    #expect(requests.count == 2)
    #expect(requests[1].topics.isEmpty)
    // …and the local join stops accepting anything, so a frame still in
    // flight from the provider cannot be evaluated on the way down.
    #expect(await joiner.stats().requiredTopics.isEmpty)
}

@Test func theJoinRuleTracksWhatWasActuallyRequested() async throws {
    // Requiring a topic nobody requested wedges the join permanently;
    // requiring less than was requested evaluates hair-pulling against a
    // mask that never arrived. Neither is a failure a test of the joiner
    // alone can see — it needs the two kept in lockstep.
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    await request.attach(host: SpyHost())

    await request.configChanged(config(enabled: true, behaviors: [.nosePicking]))
    #expect(await joiner.stats().requiredTopics == ["vision.face.v1", "vision.hands.v1"])

    await request.configChanged(config(enabled: true, behaviors: [.nosePicking, .hairPulling]))
    #expect(await joiner.stats().requiredTopics
            == ["vision.face.v1", "vision.hands.v1", "vision.segmentation.v1"])
}

@Test func reassertingRepublishesTheSameDesiredStateUnchanged() async throws {
    // The reconnect path. Events are ephemeral — a request published while
    // the provider was restarting is simply gone — so re-sending an
    // identical message is the correct behaviour, not redundant chatter.
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    let host = SpyHost()
    await request.attach(host: host)

    await request.configChanged(config(enabled: true, behaviors: [.nosePicking]))
    await request.reassert(reason: "test")

    let requests = try await host.requests()
    #expect(requests.count == 2)
    #expect(requests[0].topics == requests[1].topics)
}

@Test func retractingOnShutdownAsksForNothingRatherThanWaitingOutTheTtl() async throws {
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    let host = SpyHost()
    await request.attach(host: host)

    await request.configChanged(config(enabled: true, behaviors: BFRBBehavior.allCases))
    await request.retract()

    let requests = try await host.requests()
    #expect(requests.last?.topics.isEmpty == true)
    // Nothing further may be published after the retraction, or a demand
    // announcement racing shutdown would re-open the models we just asked
    // to have destroyed.
    await request.reassert(reason: "late demand announcement")
    #expect(try await host.requests().count == requests.count)
}

@Test func aFailedPublishIsLoggedAndSurvivedRatherThanThrownOrFatal() async throws {
    // Core may be mid-reconnect. A plugin that treated this as fatal would
    // be charged an unrequested exit, and five of those park it in
    // StateFailed until a manual dashboard restart.
    let joiner = VisionFrameJoiner()
    let request = VisionRequest(joiner: joiner)
    let host = SpyHost()
    await request.attach(host: host)
    await host.setFailNext()

    await request.configChanged(config(enabled: true, behaviors: [.nosePicking]))
    #expect(try await host.requests().isEmpty)

    // The heartbeat's whole job: the next assertion recovers it, with no
    // config change and no restart.
    await request.reassert(reason: "heartbeat")
    #expect(try await host.requests().count == 1)
}

@Test func publishingBeforeAHostIsAttachedIsSurvivable() async {
    // `main.swift` must register routes before `VCHost.connect()` can be
    // called, so nothing that needs a live host exists until after it. A
    // config change landing in that window must not crash.
    let request = VisionRequest(joiner: VisionFrameJoiner())
    await request.configChanged(config(enabled: true, behaviors: [.nosePicking]))
}

@Test func theHeartbeatSitsWellInsideTheTtl() {
    // Three attempts before a request could expire, so two lost publishes in
    // a row still cost nothing. A heartbeat at or above the TTL would mean
    // one dropped message silently closes the camera mid-session.
    let ttl = Duration.seconds(Int(VisionRequest.ttlSeconds))
    #expect(VisionRequest.heartbeat * 3 <= ttl)
}
