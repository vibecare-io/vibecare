import Foundation
import Testing
import VCKStubs
@testable import VisionKit

/// Pipeline assembly: which models run for a given demand + request state.
///
/// The rule under test is one line — a topic runs iff a live request names it
/// AND its kernel demand is non-zero — and every case below is one way that
/// conjunction can fail.
@Suite struct VisionPlannerTests {
    private let t0 = ContinuousClock.now

    private func request(_ requester: String,
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

    private func table(_ counts: [VisionTopic: Int]) -> DemandTable {
        var demand = DemandTable()
        for (topic, n) in counts { demand.apply(topic: topic.name, subscribers: n) }
        return demand
    }

    @Test func aRequestForOneTopicConstructsExactlyOneModel() {
        var requests = RequestRegistry()
        requests.apply(request("postures", [.bodyPose], fps: 2), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.bodyPose: 1]),
                                      at: t0)
        #expect(plan.models == [.bodyPose])
        #expect(plan.captureFPS == 2)
        #expect(plan.wantsCapture)
        #expect(plan.topics[.bodyPose]?.requesters == ["postures"])
    }

    @Test func demandWithoutARequestRunsNothingAndWarnsLoudly() {
        // The single most likely way to wire a new consumer up wrong: it
        // declares `subscribes: [vision.face.v1]` and never publishes a
        // request, so it receives nothing at all — indistinguishable from a
        // broken bus unless something says so.
        let plan = VisionPlanner.plan(requests: RequestRegistry(),
                                      demand: table([.face: 2]),
                                      at: t0)
        #expect(plan.models.isEmpty)
        #expect(plan.wantsCapture == false)
        #expect(plan.warnings == [VisionWarning(topic: "vision.face.v1", subscribers: 2)])
        #expect(plan.warnings[0].message == "subscriber with no request topic=vision.face.v1 subscribers=2")
    }

    @Test func aRequestWithoutDemandRunsNothingAndDoesNotWarn() {
        var requests = RequestRegistry()
        requests.apply(request("ghost", [.face]), at: t0)

        let plan = VisionPlanner.plan(requests: requests, demand: DemandTable(), at: t0)
        #expect(plan.models.isEmpty)
        #expect(plan.wantsCapture == false)
        // Zero demand is the resting state of an idle machine, not a
        // misconfiguration — warning about it would make the warning useless.
        #expect(plan.warnings.isEmpty)
    }

    @Test func everyTopicAtZeroSubscribersStopsTheSessionDespiteLiveRequests() {
        var requests = RequestRegistry()
        requests.apply(request("vibecheck", [.face, .hands, .segmentation], fps: 30), at: t0)
        requests.apply(request("postures", [.bodyPose], fps: 2), at: t0)

        // The demand floor. A consumer that died without retracting leaves its
        // request behind; the refcount is what actually closes the camera.
        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.face: 0, .hands: 0, .bodyPose: 0]),
                                      at: t0)
        #expect(plan == .idle)
        #expect(plan.captureFPS == 0)
        #expect(plan.wantsCapture == false)
    }

    @Test func anExpiredRequestStopsItsModelsEvenWhileDemandPersists() {
        var requests = RequestRegistry()
        requests.apply(request("wedged", [.face], ttl: 30), at: t0)
        let demand = table([.face: 1])

        #expect(VisionPlanner.plan(requests: requests, demand: demand, at: t0).models == [.face])

        let after = VisionPlanner.plan(requests: requests, demand: demand, at: t0 + .seconds(31))
        #expect(after.models.isEmpty)
        // Demand is still 1, so the same event that stops the model produces
        // the warning — which is right: somebody is subscribed and getting
        // nothing.
        #expect(after.warnings.map(\.topic) == ["vision.face.v1"])
    }

    @Test func captureRunsAtTheMaxOfTheRequestedRatesCappedAtThirty() {
        var requests = RequestRegistry()
        requests.apply(request("postures", [.bodyPose], fps: 2), at: t0)
        requests.apply(request("blink-jump", [.face], fps: 30), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.bodyPose: 1, .face: 1]),
                                      at: t0)
        #expect(plan.captureFPS == 30)
        // …but the per-topic rates stay independent, which is what stops the
        // 30 fps face consumer from paying for 30 fps of body-pose inference.
        #expect(plan.fps(.bodyPose) == 2)
        #expect(plan.fps(.face) == 30)
    }

    // NOTE: a `signalsRunsWithoutConstructingAModel` case used to sit here
    // asserting `plan.wantsCapture` for a signals-only request — "the frames
    // still have to arrive". That is exactly the defect: signals costs no
    // inference, so nothing produced those frames and the camera burned for a
    // topic that could never publish. The scenario is now covered, with the
    // opposite expectation, by `signalsAloneFeedNothingBecauseArithmeticIsNotAModel`.

    @Test func aTopicNobodyWantsIsNotInThePlanAtAll() {
        var requests = RequestRegistry()
        requests.apply(request("vibecheck", [.face, .hands, .segmentation]), at: t0)

        let plan = VisionPlanner.plan(
            requests: requests,
            demand: table([.face: 1, .hands: 1, .segmentation: 1, .bodyPose: 0, .signals: 0]),
            at: t0
        )
        #expect(plan.models == [.face, .hands, .segmentation])
        #expect(plan.runningTopics.map(\.name)
                == ["vision.face.v1", "vision.hands.v1", "vision.segmentation.v1"])
    }

    // MARK: - Feeder models (the one exception to the bare conjunction)

    @Test func signalsAloneFeedNothingBecauseArithmeticIsNotAModel() {
        // Naming only `signals` is not a way to get free landmarks. The
        // requester says which models it is asking somebody to pay for, and
        // this one asked for none.
        //
        // The camera must therefore stay SHUT. Signals costs no inference, so
        // a plan holding it alone would open the session, run nothing, derive
        // nothing, publish nothing — and the privacy readout would report the
        // reassuring "the camera is on because blink-jump wants signals"
        // while the LED burned for a topic that can never say a word.
        var requests = RequestRegistry()
        requests.apply(request("blink-jump", [.signals], fps: 30), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.signals: 1]),
                                      at: t0)
        #expect(plan.models.isEmpty, "a request naming no model must construct no model")
        #expect(plan.wantsCapture == false, "no model means no reason to open the camera")
        #expect(plan.topics[.signals] == nil, "a topic that can publish nothing is not running")
        #expect(plan.captureFPS == 0)
        // Silence would be the real failure: the consumer is subscribed and
        // receiving nothing, and this warning is the only thing that can tell
        // its author that naming `signals` alone feeds nothing.
        #expect(plan.warnings.map(\.kind) == [.signalsWithoutAnyModel])
        #expect(plan.warnings.map(\.topic) == ["vision.signals.v1"])
        #expect(plan.warnings.map(\.subscribers) == [1])
    }

    @Test func aSignalsConsumerThatNamesAModelGetsItRunAsAnUnpublishedFeeder() {
        // The design's §5.5 writes blink-jump's manifest as
        // `subscribes: [vision.signals.v1]` and nothing else, and §4.4
        // promises it never sees a landmark. So demand for `vision.face.v1`
        // is STRUCTURALLY zero — and under the bare conjunction the face
        // model would never run, leaving `ear_l` absent on every frame
        // forever. That is the case this rule exists for.
        var requests = RequestRegistry()
        requests.apply(request("blink-jump", [.signals, .face], fps: 30), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.signals: 1]),
                                      at: t0)
        #expect(plan.models == [.face], "the face model must run so signals have eyes to measure")
        #expect(plan.topics[.face]?.publishes == false,
                "nothing subscribes to vision.face.v1, so nothing may be published on it")
        #expect(plan.topics[.face]?.subscribers == 0, "reported as zero because it IS zero")
        #expect(plan.topics[.face]?.requesters == ["blink-jump"])
        #expect(plan.topics[.face]?.fps == 30, "a feeder slower than the topic it feeds makes signals stale")
        // The signals topic itself is the one with a live subscriber, and it
        // is published normally.
        #expect(plan.topics[.signals]?.publishes == true)
        #expect(plan.wantsCapture)
        #expect(plan.warnings.isEmpty, "a feeder has no subscribers, so it is not a misconfigured consumer")
    }

    @Test func afeederCannotHoldTheCameraOpenOnceItsSignalsSubscriberLeaves() {
        // The safety argument for the whole exception: kill the signals
        // subscriber and every feeder goes with it on the same reconcile.
        // A feeder can never be the reason the LED is on.
        var requests = RequestRegistry()
        requests.apply(request("blink-jump", [.signals, .face], fps: 30), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.signals: 0]),
                                      at: t0)
        #expect(plan.models.isEmpty)
        #expect(plan.wantsCapture == false)
    }

    @Test func aFeederIsPublishedNormallyTheMomentSomebodySubscribesToIt() {
        // Two consumers, one topic: blink-jump wants face fed to signals,
        // vibecheck genuinely subscribes to the landmarks. The topic must go
        // back to being published — the feeder flag is a property of the
        // demand state, not a sticky attribute of the topic.
        var requests = RequestRegistry()
        requests.apply(request("blink-jump", [.signals, .face], fps: 30), at: t0)
        requests.apply(request("vibecheck", [.face], fps: 15), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.signals: 1, .face: 1]),
                                      at: t0)
        #expect(plan.topics[.face]?.publishes == true)
        #expect(plan.topics[.face]?.subscribers == 1)
        #expect(plan.topics[.face]?.requesters == ["blink-jump", "vibecheck"])
        #expect(plan.topics[.face]?.fps == 30, "max() across requesters, not the last one to ask")
    }

    @Test func aFeederIsNotGrantedToARequesterThatNeverAskedForSignals() {
        // The feeder rule keys on ONE requester naming both. A plugin that
        // asked for face alone, with nobody subscribed to face, still gets
        // nothing — otherwise any live signals consumer anywhere would
        // launder every other plugin's request past the demand floor.
        var requests = RequestRegistry()
        requests.apply(request("blink-jump", [.signals], fps: 30), at: t0)
        requests.apply(request("someone-else", [.hands], fps: 30), at: t0)

        let plan = VisionPlanner.plan(requests: requests,
                                      demand: table([.signals: 1]),
                                      at: t0)
        #expect(plan.models.isEmpty)
    }
}

/// The liveness half on its own: demand is authoritative state, not a delta.
@Suite struct DemandTableTests {
    @Test func applyOverwritesRatherThanAccumulating() {
        var demand = DemandTable()
        demand.apply(topic: VisionTopic.face.name, subscribers: 3)
        demand.apply(topic: VisionTopic.face.name, subscribers: 1)
        // Adding would leave 4 and hold the camera open for two consumers that
        // never existed. Every event carries one topic's whole truth.
        #expect(demand.subscribers(.face) == 1)
    }

    @Test func aReconnectBurstIsJustMoreOverwrites() {
        var demand = DemandTable()
        for _ in 0..<5 {
            demand.apply(topic: VisionTopic.face.name, subscribers: 2)
            demand.apply(topic: VisionTopic.hands.name, subscribers: 0)
        }
        #expect(demand.subscribers(.face) == 2)
        #expect(demand.subscribers(.hands) == 0)
        #expect(demand.isSilent == false)
    }

    @Test func silenceMeansEveryVisionTopicIsAtZero() {
        var demand = DemandTable()
        #expect(demand.isSilent)
        demand.apply(topic: VisionTopic.segmentation.name, subscribers: 1)
        #expect(demand.isSilent == false)
        demand.apply(topic: VisionTopic.segmentation.name, subscribers: 0)
        #expect(demand.isSilent)
    }

    @Test func theKernelsJSONPayloadDecodes() {
        var demand = DemandTable()
        let payload = Data(#"{"topic":"vision.body_pose.v1","subscribers":4}"#.utf8)
        let decoded = demand.apply(payload: payload)
        #expect(decoded?.topic == "vision.body_pose.v1")
        #expect(demand.subscribers(.bodyPose) == 4)
    }

    @Test func anUndecodablePayloadIsIgnoredRatherThanFatal() {
        var demand = DemandTable()
        demand.apply(topic: VisionTopic.face.name, subscribers: 1)
        #expect(demand.apply(payload: Data("not json".utf8)) == nil)
        #expect(demand.subscribers(.face) == 1)
    }

}
