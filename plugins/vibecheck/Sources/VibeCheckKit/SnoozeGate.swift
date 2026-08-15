import Foundation

/// Suppresses alert popups — not detection, not counts, not the `/api/events`
/// SSE feed — until a caller-chosen deadline. Backs `GET/POST
/// /api/snooze?minutes=N`, which is also the "Snooze 10 min" action URL
/// `HostSink.fired` attaches to every detection alert (see
/// `VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10")`).
///
/// An actor, not a plain struct behind a lock, because a snooze set from one
/// HTTP request and a check made by a concurrently-firing detection must
/// never interleave torn reads/writes of `until`.
public actor SnoozeGate {
    private var until: Date?

    public init() {}

    /// `minutes <= 0` clears any active snooze rather than setting a
    /// deadline in the past. A caller passing `0` — or, from a hand-crafted
    /// query string, a negative value — reads far more naturally as "stop
    /// snoozing" than as "snooze retroactively," and a past deadline would
    /// be indistinguishable from "never snoozed" anyway (see `isActive`),
    /// so treating it as an explicit clear is both the more useful behavior
    /// and the more honest one.
    ///
    /// `now` defaults to `Date()` for callers that don't care; tests pass a
    /// fixed instant so nothing here depends on wall-clock timing.
    public func snooze(minutes: Int, now: Date = Date()) {
        guard minutes > 0 else {
            until = nil
            return
        }
        until = now.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Strict `<`, matching `DetectionPolicy`'s own cooldown convention
    /// (`time - last < cooldown`): the instant a snooze's deadline arrives,
    /// it is no longer active, rather than staying active through that same
    /// instant.
    public func isActive(now: Date = Date()) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Reported by `/api/snooze`'s response body so a client can show
    /// "snoozed until 3:41 PM" without guessing; `nil` when nothing is
    /// currently snoozed (including after it has lapsed — this does not
    /// self-clear `until` on read, but `isActive` already treats a lapsed
    /// deadline as inactive, and the next `snooze(minutes:)` call overwrites
    /// it regardless).
    public func deadline() -> Date? { until }
}
