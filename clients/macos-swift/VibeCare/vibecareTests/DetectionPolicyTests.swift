import Testing
import CoreGraphics
@testable import vibecare

private func hit(_ b: BFRBBehavior) -> DetectionResult { DetectionResult(behavior: b, point: .zero) }

@Test func firesOnlyAfterDwell() {
    var p = DetectionPolicy(dwell: 0.5, cooldown: 5)
    #expect(p.ingest(hit(.nosePicking), at: 0.0) == nil)   // dwell starts
    #expect(p.ingest(hit(.nosePicking), at: 0.3) == nil)   // not enough yet
    #expect(p.ingest(hit(.nosePicking), at: 0.6)?.behavior == .nosePicking) // confirmed
}

@Test func dwellResetsWhenHitDisappears() {
    var p = DetectionPolicy(dwell: 0.5, cooldown: 5)
    _ = p.ingest(hit(.nosePicking), at: 0.0)
    #expect(p.ingest(nil, at: 0.3) == nil)                 // gap resets dwell
    #expect(p.ingest(hit(.nosePicking), at: 0.4) == nil)   // dwell restarts
    #expect(p.ingest(hit(.nosePicking), at: 1.0)?.behavior == .nosePicking)
}

@Test func cooldownSuppressesRepeatFires() {
    var p = DetectionPolicy(dwell: 0.0, cooldown: 5)
    #expect(p.ingest(hit(.nailBiting), at: 0.0)?.behavior == .nailBiting) // immediate (dwell 0)
    #expect(p.ingest(hit(.nailBiting), at: 2.0) == nil)    // within cooldown
    #expect(p.ingest(hit(.nailBiting), at: 5.1)?.behavior == .nailBiting) // after cooldown
}

@Test func behaviorsAreIndependent() {
    var p = DetectionPolicy(dwell: 0.0, cooldown: 5)
    #expect(p.ingest(hit(.nailBiting), at: 0.0)?.behavior == .nailBiting)
    #expect(p.ingest(hit(.nosePicking), at: 0.1)?.behavior == .nosePicking) // different behavior, not suppressed
}
