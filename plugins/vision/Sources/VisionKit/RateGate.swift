import Foundation

/// Independent per-topic rate limiting.
///
/// The capture session runs at `max()` of the requested rates, so every topic
/// below that rate has to drop frames of its own — and each drops on **its
/// own** schedule. Sharing one throttle across topics is the defect this type
/// exists to prevent: `postures` at 2 fps would otherwise be dragged to 30
/// because `blink-jump` wants faces fast, paying for fifteen times the
/// body-pose inference nobody asked for.
///
/// Deliberately a value type with no clock: `due` takes `now`, so a test can
/// step a whole second of 30 fps ticks through it and count exactly how many
/// times each topic fired, with no sleeping and no flakiness.
///
/// Instants are `ContinuousClock.Instant` (monotonic). A `Date`-based gate
/// would be defeated by a backward wall-clock step: `now - last` goes negative,
/// `< interval` is then true for every frame, and every topic silently stops
/// publishing until real time catches back up.
struct RateGate: Sendable, Equatable {
    /// A frame arriving marginally early still counts.
    ///
    /// Without this, a topic requesting exactly the capture rate loses roughly
    /// a third of its frames. Camera frame spacing is not exact — at 30 fps the
    /// gaps land either side of 33.33 ms — so a strict `elapsed >= 1/fps` test
    /// rejects every gap that rounds a hair under, and the topic publishes at
    /// ~20 fps while the session pays for 30. Five percent is comfortably
    /// larger than that jitter and far smaller than the gap between any two
    /// rates a consumer would plausibly ask for, so it fixes the common rate
    /// without letting a 2 fps topic creep towards 3.
    static let earlyTolerance = 0.95

    private var last: [VisionTopic: ContinuousClock.Instant] = [:]

    init() {}

    /// Whether `topic` should run on this frame at `fps`, recording the
    /// decision when it is yes.
    ///
    /// The first call for a topic always fires: a freshly constructed model
    /// should produce a frame immediately rather than after one full interval,
    /// which at 2 fps is half a second of a consumer seeing nothing.
    mutating func due(_ topic: VisionTopic, fps: Int, at now: ContinuousClock.Instant) -> Bool {
        guard fps > 0 else { return false }
        let interval = Self.earlyTolerance / TimeInterval(fps)
        if let previous = last[topic], visionSeconds(now - previous) < interval {
            return false
        }
        last[topic] = now
        return true
    }

    /// Forgets a topic's schedule. Called when its model is released, so that
    /// a topic re-requested later fires immediately instead of waiting out an
    /// interval measured from before it was switched off.
    mutating func forget(_ topics: some Sequence<VisionTopic>) {
        for topic in topics { last.removeValue(forKey: topic) }
    }

    /// Every topic due on this frame, given the plan. Sorted only so the
    /// caller's logs and tests see a stable order; the set is what matters.
    mutating func dueTopics(for plan: VisionPlan, at now: ContinuousClock.Instant) -> Set<VisionTopic> {
        var due: Set<VisionTopic> = []
        for topic in plan.runningTopics {
            if self.due(topic, fps: plan.topics[topic]!.fps, at: now) { due.insert(topic) }
        }
        return due
    }
}
