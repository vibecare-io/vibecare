import Testing
import Foundation
import VCKStubs
import VCPluginSDK
@testable import PosturesKit

/// Records what a `VisionRequester`/`PostureMonitor` actually put on the
/// wire. `VCHost` dials a real gRPC socket in `connect()` and cannot be
/// constructed in a test, which is the whole reason `PostureHost` exists.
actor SpyHost: PostureHost {
    struct Published: Sendable {
        let topic: String
        let payload: Data
    }

    private(set) var published: [Published] = []
    private(set) var alerts: [VCAlert] = []
    /// When set, every call throws it — core mid-reconnect, from the
    /// plugin's point of view.
    var failure: (any Error)?

    func publish(topic: String, payload: Data) async throws {
        if let failure { throw failure }
        published.append(Published(topic: topic, payload: payload))
    }

    func alert(_ a: VCAlert) async throws {
        if let failure { throw failure }
        alerts.append(a)
    }

    func setFailure(_ e: (any Error)?) { failure = e }

    /// Decoded `vision.request.v1` messages, in order.
    func requests() -> [VCTRequest] {
        published
            .filter { $0.topic == VisionRequest.topic }
            .compactMap { try? VCTRequest(serializedBytes: $0.payload) }
    }
}

struct SpyError: Error, Equatable {}

// MARK: - The message itself

@Test func anEnabledRequestNamesEveryTopicPosturesSubscribesTo() {
    // §5.3's rule is per topic: a consumer subscribed to a topic no live
    // request names receives nothing at all, which is indistinguishable from
    // a broken bus. Both subscribed topics must therefore be requested.
    let r = VisionRequest.message(requester: "postures", enabled: true)
    #expect(r.requester == "postures")
    #expect(r.topics == ["vision.body_pose.v1", "vision.signals.v1"])
    #expect(r.fps == 2)
    #expect(r.ttlS == 30)
}

@Test func theRequestedTopicsAreExactlyTheManifestsSubscribes() {
    // Pinned against the literal strings in manifest.yaml. A rename on either
    // side that misses the other is a plugin that silently receives nothing.
    #expect(VisionRequest.bodyPoseTopic == "vision.body_pose.v1")
    #expect(VisionRequest.signalsTopic == "vision.signals.v1")
    #expect(VisionRequest.topic == "vision.request.v1")
}

@Test func aDisabledRequestIsAnExplicitEmptyTopicListNotSilence() {
    // Silence would only expire after the TTL, leaving vision running a model
    // for a feature the user just switched off. The empty list is what makes
    // "user disables postures" close the camera immediately.
    let r = VisionRequest.message(requester: "postures", enabled: false)
    #expect(r.topics.isEmpty)
    // fps is still the real number. `0` is NOT neutral — the spec reads an
    // absent or zero fps as the default 15 — so sending it would be the one
    // value that could be misread.
    #expect(r.fps == 2)
}

@Test func theHeartbeatSitsWellInsideTheTTL() {
    // Two consecutive lost heartbeats must still not expire the request.
    #expect(VisionRequest.heartbeat * 2 < TimeInterval(VisionRequest.ttlSeconds))
}

// MARK: - Lifecycle

@Test func enablingAssertsTheRequestImmediately() async {
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures")
    await requester.attach(host: host)

    await requester.setEnabled(true)
    let requests = await host.requests()
    #expect(requests.count == 1)
    #expect(requests[0].topics == VisionRequest.topics)
    #expect(await requester.lastAssertedTopics == VisionRequest.topics)
    #expect(await requester.lastAssertedAt != nil)
}

@Test func disablingRetractsTheRequest() async {
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures")
    await requester.attach(host: host)

    await requester.setEnabled(true)
    await requester.setEnabled(false)
    let requests = await host.requests()
    #expect(requests.count == 2)
    #expect(requests[1].topics.isEmpty)
    #expect(await requester.lastAssertedTopics.isEmpty)
}

@Test func reassertRepublishesTheCurrentDesiredStateVerbatim() async {
    // Latest-wins per requester, so an extra assertion costs one small
    // message and changes nothing — which is exactly what makes it safe to
    // fire on every demand burst.
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures")
    await requester.attach(host: host)

    await requester.setEnabled(true)
    await requester.reassert()
    await requester.reassert()
    let requests = await host.requests()
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.topics == VisionRequest.topics })
    #expect(requests.allSatisfy { $0.requester == "postures" })
}

@Test func aFailedPublishIsRecordedAndNeverThrownAtTheCaller() async {
    // Core may simply be mid-reconnect. Throwing out of here would propagate
    // into the event loop; exiting would be charged a failed start.
    let host = SpyHost()
    await host.setFailure(SpyError())
    let requester = VisionRequester(requester: "postures")
    await requester.attach(host: host)

    await requester.setEnabled(true)
    #expect(await requester.lastError != nil)
    #expect(await requester.lastAssertedAt == nil)
    #expect(await requester.assertCount == 0)

    // ...and the next assertion recovers without any special handling.
    await host.setFailure(nil)
    await requester.reassert()
    #expect(await requester.lastError == nil)
    #expect(await requester.assertCount == 1)
}

@Test func assertingBeforeAHostExistsIsRecordedRatherThanCrashing() async {
    // Routes — and everything they close over — must be built before
    // `VCHost.connect()` can be called at all, so there is genuinely a window
    // with no host.
    let requester = VisionRequester(requester: "postures")
    await requester.setEnabled(true)
    #expect(await requester.lastError == "no host attached yet")
}

@Test func theHeartbeatKeepsReassertingWithoutAnyExternalPrompt() async throws {
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures", heartbeatInterval: 0.02)
    await requester.attach(host: host)
    await requester.setEnabled(true)
    await requester.startHeartbeat()

    // Poll rather than sleeping a fixed span, so a slow machine cannot make
    // this flaky and a broken heartbeat still fails it.
    var count = 0
    for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(10))
        count = await host.requests().count
        if count >= 4 { break }
    }
    #expect(count >= 4)
    await requester.stop()
}

@Test func stopRetractsTheRequestAndSilencesTheHeartbeat() async throws {
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures", heartbeatInterval: 0.02)
    await requester.attach(host: host)
    await requester.setEnabled(true)
    await requester.startHeartbeat()
    try await Task.sleep(for: .milliseconds(60))

    await requester.stop()
    let afterStop = await host.requests()
    // The last thing on the wire is a retraction — what lets vision destroy
    // the model a beat before our subscription drops and the demand floor
    // does it anyway.
    #expect(afterStop.last?.topics.isEmpty == true)

    try await Task.sleep(for: .milliseconds(120))
    #expect(await host.requests().count == afterStop.count)
}
