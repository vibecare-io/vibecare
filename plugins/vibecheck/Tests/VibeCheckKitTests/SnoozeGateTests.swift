import Testing
import Foundation
@testable import VibeCheckKit

// `SnoozeGate` backs `GET/POST /api/snooze?minutes=N` — the "Snooze 10 min"
// action button on every detection alert. It has no camera/Vision
// dependency at all (pure `Date` arithmetic behind an actor), so unlike
// most of `DetectionEngine`'s own concurrency this is fully and honestly
// unit-testable: every assertion below drives it with an injected `now`,
// never a real clock, so there is no sleep and no flakiness.

@Test func freshGateIsNotSnoozed() async {
    let gate = SnoozeGate()
    #expect(await gate.isActive() == false)
    #expect(await gate.deadline() == nil)
}

@Test func snoozingSetsAFutureDeadlineThatIsActive() async {
    let gate = SnoozeGate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 10, now: now)

    let deadline = await gate.deadline()
    #expect(deadline == now.addingTimeInterval(600))
    #expect(await gate.isActive(now: now) == true)
    // Still inside the window, one second before it lapses.
    #expect(await gate.isActive(now: now.addingTimeInterval(599)) == true)
}

@Test func snoozeExpiresExactlyAtItsDeadline() async {
    let gate = SnoozeGate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 1, now: now)

    // `isActive` is a strict `<`, matching DetectionPolicy's own cooldown
    // convention (`time - last < cooldown`) rather than `<=` — a deadline
    // that includes its own instant would make "snoozed until exactly now"
    // ambiguous about whether the very next alert at that instant fires.
    #expect(await gate.isActive(now: now.addingTimeInterval(60)) == false)
}

@Test func zeroOrNegativeMinutesClearsAnActiveSnoozeInsteadOfBackdatingIt() async {
    let gate = SnoozeGate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 10, now: now)
    #expect(await gate.isActive(now: now) == true)

    // A caller passing 0 (or, from a hand-crafted query string, a negative
    // value) means "stop snoozing" — the one reading that doesn't produce
    // a nonsensical already-expired-in-the-past deadline.
    await gate.snooze(minutes: 0, now: now)
    #expect(await gate.isActive(now: now) == false)
    #expect(await gate.deadline() == nil)
}

@Test func aLaterSnoozeCallReplacesTheEarlierDeadline() async {
    let gate = SnoozeGate()
    let now = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 10, now: now)
    await gate.snooze(minutes: 1, now: now)
    #expect(await gate.deadline() == now.addingTimeInterval(60))
}
