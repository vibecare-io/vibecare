import Foundation

struct BFRBEvent: Sendable, Equatable {
    let behavior: BFRBBehavior
    let time: TimeInterval
}

/// Turns a stream of per-frame DetectionResults into confirmed events.
/// A behavior must persist continuously for `dwell` seconds to fire, then is
/// suppressed for `cooldown` seconds. Pure/deterministic given (result, time).
struct DetectionPolicy {
    var dwell: TimeInterval
    var cooldown: TimeInterval

    private var dwellStart: [BFRBBehavior: TimeInterval] = [:]
    private var lastFired: [BFRBBehavior: TimeInterval] = [:]

    init(dwell: TimeInterval, cooldown: TimeInterval) {
        self.dwell = dwell
        self.cooldown = cooldown
    }

    mutating func ingest(_ result: DetectionResult?, at time: TimeInterval) -> BFRBEvent? {
        // No hit this frame → clear all dwell timers (continuity broken).
        guard let result else { dwellStart.removeAll(); return nil }
        let b = result.behavior

        // Reset any *other* behaviors' dwell (only one region active at a time).
        for key in dwellStart.keys where key != b { dwellStart[key] = nil }

        let start = dwellStart[b] ?? time
        dwellStart[b] = start

        if time - start < dwell { return nil }
        if let last = lastFired[b], time - last < cooldown { return nil }

        lastFired[b] = time
        dwellStart[b] = nil
        return BFRBEvent(behavior: b, time: time)
    }
}
