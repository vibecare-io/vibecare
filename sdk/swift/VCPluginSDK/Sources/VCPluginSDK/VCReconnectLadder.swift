import Foundation

/// Backoff for the Register stream, as a value type so it can be tested
/// without a network. Pulled out of the reconnect loop deliberately: the
/// Go SDK's equivalent is welded into a `for` and has never been tested.
///
/// The 8s cap is tighter than the Go SDK's 30s on purpose. While the stream
/// is down core demotes the plugin to starting("reconnecting") and the proxy
/// serves a 503 page for /p/<id>/, so the upper rungs are visible downtime.
public struct VCReconnectLadder: Sendable, Equatable {
    public var base: TimeInterval = 1
    public var cap: TimeInterval = 8
    public var stableAfter: TimeInterval = 60

    private var failures: Int = 0

    public init() {}

    /// Call when a session ends, however it ended. Returns how long to wait
    /// before the next attempt.
    public mutating func sessionEnded(lastedSeconds: TimeInterval) -> TimeInterval {
        if lastedSeconds >= stableAfter { failures = 0 }
        let delay = min(cap, base * pow(2, Double(failures)))
        failures += 1
        return delay
    }

    public mutating func reset() { failures = 0 }
}
