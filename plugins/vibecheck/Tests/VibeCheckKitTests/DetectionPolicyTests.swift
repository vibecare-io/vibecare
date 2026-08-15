import Testing
import Foundation
import CoreGraphics
@testable import VibeCheckKit

private func hit(_ b: BFRBBehavior) -> DetectionResult {
    DetectionResult(behavior: b, point: CGPoint(x: 0.5, y: 0.5))
}

@Test func firesOnlyAfterContinuousDwell() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    #expect(p.ingest(hit(.nailBiting), at: 0) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.10) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.20)?.behavior == .nailBiting)
}

@Test func anyGapResetsDwell() {
    // Dwell is CONTINUOUS presence, not a hit count. One frame without a hit
    // — hand leaves frame, Vision misses, confidence dips — starts over.
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(nil, at: 0.10) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.20) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.40)?.behavior == .nailBiting)
}

@Test func cooldownSuppressesRepeatsOfTheSameBehavior() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(hit(.nailBiting), at: 0.2)?.behavior == .nailBiting)
    _ = p.ingest(hit(.nailBiting), at: 1.0)
    #expect(p.ingest(hit(.nailBiting), at: 2.0) == nil)     // inside cooldown
    // NOTE: deviates from the task-9-brief.md Step 1 listing, which has an
    // uninterrupted run of nailBiting hits from t=1.0 straight through to
    // t=6.5. Under the verbatim (unmodified) DetectionPolicy algorithm,
    // dwellStart is only cleared on an actual fire or on a frame with no
    // hit — never merely by a cooldown-blocked frame. So with continuous
    // presence, dwellStart stays pinned at 1.0 the whole time, dwell is
    // already satisfied long before cooldown clears, and the moment
    // cooldown clears (elapsed since lastFired 0.2 >= 5, i.e. at t=6.0) the
    // policy fires immediately — consuming the very call the brief expects
    // to discard, so the brief's final assertion at t=6.5 (freshly
    // requiring another 0.15s of dwell after that unaccounted-for fire)
    // cannot pass. Verified by running the brief's literal test verbatim:
    // it fails this way (see task-7-9-report.md). Preserving
    // DetectionPolicy's logic unmodified per the task's explicit
    // constraint, this test instead inserts a gap before the final hit so
    // dwell genuinely re-accumulates, which is what the brief's comments
    // describe.
    _ = p.ingest(nil, at: 5.9)
    _ = p.ingest(hit(.nailBiting), at: 6.0)
    #expect(p.ingest(hit(.nailBiting), at: 6.5)?.behavior == .nailBiting)
}

@Test func cooldownIsPerBehaviorSoTwoCanFireBackToBack() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(hit(.nailBiting), at: 0.2)?.behavior == .nailBiting)
    _ = p.ingest(hit(.nosePicking), at: 0.3)
    #expect(p.ingest(hit(.nosePicking), at: 0.5)?.behavior == .nosePicking)
}

@Test func dwellIsExclusiveAcrossBehaviors() {
    // Switching regions restarts the clock; you cannot accumulate dwell on
    // two behaviors at once.
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    _ = p.ingest(hit(.nosePicking), at: 0.10)
    #expect(p.ingest(hit(.nailBiting), at: 0.16) == nil)
}
