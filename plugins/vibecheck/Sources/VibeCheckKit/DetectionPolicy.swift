import Foundation

public struct BFRBEvent: Sendable, Equatable {
    public let behavior: BFRBBehavior
    public let time: TimeInterval

    public init(behavior: BFRBBehavior, time: TimeInterval) {
        self.behavior = behavior
        self.time = time
    }
}

/// Turns a stream of per-frame DetectionResults into confirmed events.
/// A behavior must persist continuously for `dwell` seconds to fire, then is
/// suppressed for `cooldown` seconds. Pure/deterministic given (result, time).
public struct DetectionPolicy {
    public var dwell: TimeInterval
    public var cooldown: TimeInterval

    private var dwellStart: [BFRBBehavior: TimeInterval] = [:]
    private var lastFired: [BFRBBehavior: TimeInterval] = [:]

    public init(dwell: TimeInterval, cooldown: TimeInterval) {
        self.dwell = dwell
        self.cooldown = cooldown
    }

    public mutating func ingest(_ result: DetectionResult?, at time: TimeInterval) -> BFRBEvent? {
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
