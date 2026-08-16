import Foundation
import Testing
import VCKStubs
@testable import VisionKit

/// The intent half of the control plane: latest-wins per requester, the union
/// across requesters, and TTL expiry.
///
/// Every assertion drives an explicit `ContinuousClock.Instant` rather than
/// sleeping — `RequestRegistry` deliberately has no clock of its own for
/// exactly this reason, so "a wedged consumer's request expires" is a
/// microsecond-fast, non-flaky test rather than a 30-second one.
@Suite struct RequestRegistryTests {
    private let t0 = ContinuousClock.now

    private func message(_ requester: String,
                         _ topics: [VisionTopic],
                         fps: UInt32 = 0,
                         ttl: UInt32 = 0) -> VCTRequest {
        var request = VCTRequest()
        request.requester = requester
        request.topics = topics.map(\.name)
        request.fps = fps
        request.ttlS = ttl
        return request
    }

    @Test func defaultsResolveFPSAndTTL() {
        var registry = RequestRegistry()
        registry.apply(message("blink-jump", [.signals]), at: t0)

        let live = registry.live(at: t0)
        #expect(live.count == 1)
        // "0 or absent means the default, 15" and "0 means the default, 30".
        #expect(live[0].fps == RequestRegistry.defaultFPS)
        #expect(live[0].ttl == RequestRegistry.defaultTTL)
    }

    @Test func fpsIsCappedAtTheCaptureCeiling() {
        var registry = RequestRegistry()
        registry.apply(message("greedy", [.face], fps: 240), at: t0)
        #expect(registry.live(at: t0)[0].fps == RequestRegistry.maxFPS)
    }

    @Test func unionTakesTheMaxRatePerTopicAndNamesEveryRequester() {
        var registry = RequestRegistry()
        registry.apply(message("vibecheck", [.face, .hands], fps: 15), at: t0)
        registry.apply(message("blink-jump", [.face], fps: 30), at: t0)
        registry.apply(message("postures", [.bodyPose], fps: 2), at: t0)

        let intent = registry.intent(at: t0)
        // Per-topic and independent: body pose stays at 2 even though someone
        // else wants faces at 30. That independence is the whole point — the
        // alternative drags body-pose inference to 30 and pays fifteen times
        // the ANE cost nobody asked for.
        #expect(intent[.face]?.fps == 30)
        #expect(intent[.hands]?.fps == 15)
        #expect(intent[.bodyPose]?.fps == 2)
        #expect(intent[.face]?.requesters == ["blink-jump", "vibecheck"])
        #expect(intent[.bodyPose]?.requesters == ["postures"])
        // A topic nobody asked for is ABSENT, not present at zero.
        #expect(intent[.segmentation] == nil)
    }

    @Test func latestWinsPerRequester() {
        var registry = RequestRegistry()
        registry.apply(message("vibecheck", [.face, .hands, .segmentation], fps: 15), at: t0)
        registry.apply(message("vibecheck", [.face], fps: 5), at: t0 + .seconds(1))

        let intent = registry.intent(at: t0 + .seconds(1))
        #expect(intent[.face]?.fps == 5)
        #expect(intent[.hands] == nil)
        #expect(intent[.segmentation] == nil)
        #expect(registry.live(at: t0 + .seconds(1)).count == 1)
    }

    @Test func oneRequesterRetractingLeavesTheOthersAlone() {
        var registry = RequestRegistry()
        registry.apply(message("vibecheck", [.face, .hands]), at: t0)
        registry.apply(message("postures", [.bodyPose]), at: t0)

        // "user disables vibecheck -> it publishes {topics: []}" — its process
        // stays up and stays subscribed.
        registry.apply(message("vibecheck", []), at: t0 + .seconds(1))

        let now = t0 + .seconds(1)
        let intent = registry.intent(at: now)
        #expect(intent[.face] == nil)
        #expect(intent[.hands] == nil)
        #expect(intent[.bodyPose]?.requesters == ["postures"])
        // Still LIVE, just wanting nothing. That is a more useful readout than
        // "vibecheck is not here", and the two are genuinely different states.
        #expect(registry.live(at: now).map(\.requester) == ["postures", "vibecheck"])
    }

    @Test func aRequestExpiresAtItsTTLAndNotBefore() {
        var registry = RequestRegistry()
        registry.apply(message("wedged", [.face], ttl: 30), at: t0)

        #expect(registry.live(at: t0 + .seconds(29)).count == 1)
        #expect(registry.intent(at: t0 + .seconds(29))[.face] != nil)

        // At exactly the TTL it is gone: `isLive` is `now < expiresAt`.
        #expect(registry.live(at: t0 + .seconds(30)).isEmpty)
        #expect(registry.intent(at: t0 + .seconds(30))[.face] == nil)
    }

    @Test func expireDropsDeadRequestersAndReportsThem() {
        var registry = RequestRegistry()
        registry.apply(message("wedged", [.face], ttl: 10), at: t0)
        registry.apply(message("healthy", [.hands], ttl: 30), at: t0)

        let dropped = registry.expire(at: t0 + .seconds(11))
        #expect(dropped == ["wedged"])
        #expect(registry.live(at: t0 + .seconds(11)).map(\.requester) == ["healthy"])
    }

    @Test func aHeartbeatInsideTheTTLKeepsARequestAlive() {
        var registry = RequestRegistry()
        registry.apply(message("vibecheck", [.face], ttl: 30), at: t0)
        // Re-asserted every 10s against a 30s TTL, exactly as the design says
        // consumers must.
        for beat in 1...6 {
            registry.apply(message("vibecheck", [.face], ttl: 30), at: t0 + .seconds(10 * beat))
        }
        #expect(registry.live(at: t0 + .seconds(65)).count == 1)
    }

    @Test func unknownTopicNamesAreIgnoredWithoutLosingTheKnownOnes() {
        var registry = RequestRegistry()
        var request = VCTRequest()
        request.requester = "typo"
        request.topics = ["vision.face.v1", "vision.faces.v1", "audio.vad.v1"]
        registry.apply(request, at: t0)

        #expect(registry.live(at: t0)[0].topics == [.face])
    }

    @Test func anEmptyRequesterIsRejectedRatherThanCollidingWithEveryOtherOne() {
        var registry = RequestRegistry()
        // The field is how latest-wins tells consumers apart, so accepting an
        // empty one would let every anonymous publisher overwrite every other.
        #expect(registry.apply(message("", [.face]), at: t0) == false)
        #expect(registry.apply(message("   ", [.face]), at: t0) == false)
        #expect(registry.live(at: t0).isEmpty)
    }

    @Test func requesterIsWhitespaceTrimmedSoAHeartbeatMatchesItsFirstRequest() {
        var registry = RequestRegistry()
        registry.apply(message("vibecheck", [.face]), at: t0)
        registry.apply(message(" vibecheck\n", [.hands]), at: t0 + .seconds(1))
        #expect(registry.live(at: t0 + .seconds(1)).count == 1)
        #expect(registry.intent(at: t0 + .seconds(1))[.face] == nil)
    }
}
