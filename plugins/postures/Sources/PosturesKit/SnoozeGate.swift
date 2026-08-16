import Foundation

/// Suppresses posture alerts — not the vision request, not the reading in
/// `/api/state` — until a caller-chosen deadline. Backs `GET/POST
/// /api/snooze?minutes=N`, which is also the "Snooze 30 min" action URL that
/// rides on every nudge alert.
///
/// Deliberately NOT persisted. A snooze is a statement about the next half
/// hour ("I'm on a call, leave me alone"), and one that survived a core
/// restart three days later would silently suppress a nudge the user had long
/// since forgotten asking for.
///
/// An actor, not a struct behind a lock, because a snooze set from an HTTP
/// request and a check made by a concurrently-firing nudge must never
/// interleave torn reads and writes of `until`.
public actor SnoozeGate {
    private var until: Date?

    public init() {}

    /// `minutes <= 0` clears any active snooze rather than setting a deadline
    /// in the past. A caller passing `0` — or a negative value from a
    /// hand-crafted query string — reads far more naturally as "stop
    /// snoozing", and a past deadline would be indistinguishable from "never
    /// snoozed" anyway (see `isActive`).
    public func snooze(minutes: Int, now: Date = Date()) {
        guard minutes > 0 else {
            until = nil
            return
        }
        until = now.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Strict `<`, matching `PosturePolicy`'s own cooldown convention: the
    /// instant a snooze's deadline arrives it is no longer active, rather
    /// than staying active through that same instant.
    public func isActive(now: Date = Date()) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Reported by `/api/snooze` and `/api/state` so a client can render
    /// "snoozed until 3:41 PM" without guessing. `nil` when nothing is
    /// snoozed, including after a deadline has lapsed — this does not
    /// self-clear on read, but `isActive` already treats a lapsed deadline as
    /// inactive and the next `snooze(minutes:)` overwrites it regardless.
    public func deadline() -> Date? { until }
}
