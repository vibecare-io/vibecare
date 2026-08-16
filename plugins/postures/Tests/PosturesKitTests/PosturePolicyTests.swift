import Testing
import Foundation
@testable import PosturesKit

// The scoring policy is the whole product opinion of this plugin, and it is
// the one part that cannot be checked by looking at the UI: everything it
// decides is about the passage of time. So it is driven here with an explicit
// clock and no wall-clock timing anywhere.

private let poor = PostureVerdict.poor([.forwardHead])

@Test func firesOnlyAfterContinuousDwell() {
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    #expect(p.ingest(poor, at: 0) == nil)
    #expect(p.ingest(poor, at: 60) == nil)
    #expect(p.ingest(poor, at: 119.9) == nil)
    let nudge = p.ingest(poor, at: 120)
    #expect(nudge != nil)
    #expect(nudge?.faults == [.forwardHead])
    // Quoted in the alert copy, so it has to be the real elapsed time and not
    // simply `dwell` echoed back.
    #expect(nudge?.sustained == 120)
}

@Test func recoveryEndsTheRunImmediately() {
    // Recovery has NO grace in this direction: a user who straightens up has
    // genuinely stopped slouching. One good frame and the 119 seconds behind
    // it are gone.
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(.good, at: 119) == nil)
    #expect(p.ingest(poor, at: 120) == nil)
    #expect(p.ingest(poor, at: 239) == nil)
    #expect(p.ingest(poor, at: 240) != nil)   // 120 s measured from t=120
}

@Test func cooldownSuppressesTheNextNudge() {
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(poor, at: 120) != nil)
    // Still slouching, continuously, for another quarter hour — and told
    // about it exactly once.
    #expect(p.ingest(poor, at: 300) == nil)
    #expect(p.ingest(poor, at: 600) == nil)
    #expect(p.ingest(poor, at: 1019) == nil)
    #expect(p.ingest(poor, at: 1020) != nil)   // 120 + 900
}

@Test func aCooldownBlockedRunDoesNotRestartItsDwell() {
    // The subtle half of the cooldown: once the dwell is met, `poorSince` is
    // LEFT SET while the cooldown blocks, so the nudge fires the moment the
    // cooldown lapses. If a cooldown-blocked frame cleared the run instead,
    // the real interval would silently become cooldown + dwell — 7 minutes
    // here, not the 5 the user configured.
    var p = PosturePolicy(dwell: 120, cooldown: 300)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(poor, at: 120) != nil)     // fires; lastFired = 120

    // A firing DOES clear the run, so the next one starts accumulating from
    // the next frame.
    _ = p.ingest(poor, at: 121)
    #expect(p.ingest(poor, at: 241) == nil)     // dwell met at 241, cooldown blocks
    #expect(p.ingest(poor, at: 419) == nil)
    let second = p.ingest(poor, at: 420)        // exactly `cooldown` after the first
    #expect(second != nil)
    // Measured from t=121, and far longer than `dwell` — which is why the
    // alert quotes `sustained` rather than the configured dwell.
    #expect(second?.sustained == 299)
}

@Test func aFiringClearsTheRunSoTheNextOneNeedsItsOwnDwell() {
    // The other side of the same coin, stated separately because it is the
    // half that stops one long slouch from firing twice in quick succession
    // the instant a short cooldown lapses.
    var p = PosturePolicy(dwell: 120, cooldown: 60)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(poor, at: 120) != nil)
    #expect(p.ingest(poor, at: 181) == nil)     // cooldown lapsed, dwell has not
    #expect(p.ingest(poor, at: 240) == nil)
    #expect(p.ingest(poor, at: 301) != nil)     // 120 s from t=181
}

@Test func recoveryDuringCooldownStillRequiresAFreshDwell() {
    var p = PosturePolicy(dwell: 120, cooldown: 300)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(poor, at: 120) != nil)
    _ = p.ingest(.good, at: 200)            // straightened up
    _ = p.ingest(poor, at: 400)             // and slumped again after cooldown
    #expect(p.ingest(poor, at: 480) == nil) // only 80 s of the new run
    #expect(p.ingest(poor, at: 520) != nil) // 120 s of it
}

@Test func aBriefUnknownDoesNotThrowAwayTheRun() {
    // At 2 fps a 120 s dwell is 240 frames. Vision drops joints below the
    // confidence threshold for entirely ordinary reasons — a hand crosses a
    // shoulder, the chair swivels — and if one such frame reset the timer the
    // nudge would essentially never fire.
    var p = PosturePolicy(dwell: 120, cooldown: 900, unknownGrace: 5)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(.unknown, at: 60) == nil)
    #expect(p.ingest(.unknown, at: 62) == nil)
    #expect(p.ingest(poor, at: 63) == nil)
    // The run survived the blip, so the original t=0 start still holds.
    #expect(p.ingest(poor, at: 120) != nil)
}

@Test func sustainedUnknownBreaksTheRunAfterTheGrace() {
    var p = PosturePolicy(dwell: 120, cooldown: 900, unknownGrace: 5)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(.unknown, at: 60) == nil)
    #expect(p.ingest(.unknown, at: 66) == nil)   // 6 s of unknown > 5 s grace
    // The user left the desk. Whatever happened while nobody could see is not
    // evidence of anything, so the dwell restarts from the next poor frame.
    #expect(p.ingest(poor, at: 120) == nil)
    #expect(p.ingest(poor, at: 239) == nil)
    #expect(p.ingest(poor, at: 240) != nil)
}

@Test func unknownNeverFiresEvenWhenTheDwellIsAlreadySatisfied() {
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    _ = p.ingest(poor, at: 0)
    // 200 s of poor posture: the dwell is long since satisfied, and a policy
    // that fired on whatever verdict happened to arrive next would nudge here.
    #expect(p.ingest(.unknown, at: 200) == nil)
    #expect(p.ingest(.unknown, at: 201) == nil)
}

@Test func theUnknownGraceResetsOnEveryMeasuredFrame() {
    // Alternating poor/unknown must never accumulate towards the grace: each
    // measured frame is fresh evidence that we can still see.
    var p = PosturePolicy(dwell: 120, cooldown: 900, unknownGrace: 5)
    _ = p.ingest(poor, at: 0)
    for t in stride(from: 10.0, through: 110.0, by: 10.0) {
        #expect(p.ingest(.unknown, at: t) == nil)
        #expect(p.ingest(poor, at: t + 1) == nil)
    }
    #expect(p.ingest(poor, at: 120) != nil)
}

@Test func resetForgetsTheRunButNotTheCooldown() {
    // Otherwise "edit any setting" would be a way to bypass the cooldown and
    // get nudged again immediately — the one thing the cooldown exists to
    // prevent.
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    _ = p.ingest(poor, at: 0)
    #expect(p.ingest(poor, at: 120) != nil)
    p.reset()
    _ = p.ingest(poor, at: 200)
    #expect(p.ingest(poor, at: 400) == nil)     // dwell met, cooldown blocks
    #expect(p.ingest(poor, at: 1020) != nil)    // 120 + 900
}

@Test func poorForReportsTheRunInProgress() {
    var p = PosturePolicy(dwell: 120, cooldown: 900)
    #expect(p.poorFor(at: 0) == nil)
    _ = p.ingest(poor, at: 10)
    #expect(p.poorFor(at: 40) == 30)
    _ = p.ingest(.good, at: 41)
    #expect(p.poorFor(at: 50) == nil)
}

@Test func faultsOnTheNudgeAreTheOnesFromTheFiringFrame() {
    var p = PosturePolicy(dwell: 10, cooldown: 900)
    _ = p.ingest(.poor([.forwardHead]), at: 0)
    let nudge = p.ingest(.poor([.forwardHead, .unevenShoulders]), at: 10)
    #expect(nudge?.faults == [.forwardHead, .unevenShoulders])
}
