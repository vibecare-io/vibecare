import Foundation
import Testing
@testable import VisionKit

/// Per-topic rates are independent.
///
/// This is the property the design calls out by name: "postures at 2 fps must
/// not drag body-pose inference to 60 because blink-jump wants faces fast."
/// The gate takes `now` rather than reading a clock, so a whole second of
/// 30 fps ticks runs in microseconds and the counts are exact rather than
/// approximately-right-if-the-machine-is-not-busy.
@Suite struct RateGateTests {
    private let t0 = ContinuousClock.now

    @Test func theFirstFrameForATopicAlwaysFires() {
        var gate = RateGate()
        // A freshly constructed model should produce a frame immediately. At
        // 2 fps, waiting out one full interval first is half a second of a
        // consumer receiving nothing for no reason.
        let fired = gate.due(.bodyPose, fps: 2, at: t0)
        #expect(fired)
    }

    @Test func aFastAndASlowTopicKeepTheirOwnSchedules() {
        var gate = RateGate()
        var faceFrames = 0
        var bodyFrames = 0

        // One second of capture at 30 fps — the session rate is max(requested).
        // Ticks are integer milliseconds, so the gaps alternate between 33 and
        // 34 ms exactly as a real camera's do; the gate's early tolerance is
        // what keeps the 30 fps topic from losing every short one.
        for tick in 0..<30 {
            let now = t0 + .milliseconds(1000 * tick / 30)
            if gate.due(.face, fps: 30, at: now) { faceFrames += 1 }
            if gate.due(.bodyPose, fps: 2, at: now) { bodyFrames += 1 }
        }

        #expect(faceFrames == 30)
        // t=0 and t=0.5s. Fifteen times less inference than the capture rate,
        // which is the entire saving.
        #expect(bodyFrames == 2)
    }

    @Test func aZeroRateNeverFires() {
        var gate = RateGate()
        let fired = gate.due(.face, fps: 0, at: t0)
        #expect(fired == false)
    }

    @Test func forgettingATopicLetsItFireImmediatelyOnItsNextRequest() {
        var gate = RateGate()
        let first = gate.due(.face, fps: 2, at: t0)
        #expect(first)
        let tooSoon = gate.due(.face, fps: 2, at: t0 + .milliseconds(100))
        #expect(tooSoon == false)

        // The model was released — its schedule goes with it, so a consumer
        // re-requesting the topic does not wait out an interval measured from
        // before it was switched off.
        gate.forget([.face])
        let afterForget = gate.due(.face, fps: 2, at: t0 + .milliseconds(101))
        #expect(afterForget)
    }

    @Test func dueTopicsReadsEachTopicsOwnRateOutOfThePlan() {
        var gate = RateGate()
        let plan = testPlan([.face: 30, .bodyPose: 2, .signals: 30])

        #expect(gate.dueTopics(for: plan, at: t0) == [.face, .bodyPose, .signals])
        // 1/30s later: the 30 fps topics are due again, the 2 fps one is not.
        #expect(gate.dueTopics(for: plan, at: t0 + .milliseconds(34)) == [.face, .signals])
    }

    @Test func anIdlePlanHasNothingDue() {
        var gate = RateGate()
        #expect(gate.dueTopics(for: .idle, at: t0).isEmpty)
    }
}
