import Testing
import Foundation
import CoreGraphics
@testable import VibeCheckKit

// MARK: - Test doubles

private actor SpySink: DetectionSink {
    // Named `calls`, not `fired` — a stored property and a method cannot
    // share a base name in Swift, and the protocol requirement is `fired`.
    private(set) var calls: [(BFRBBehavior, Int)] = []
    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        calls.append((behavior, count))
    }
}

/// Placeholder sink for `makeTestEngine`'s construction — every test replaces
/// it immediately via `setSink(_:)`, so this is never actually asserted on.
private struct NoopSink: DetectionSink {
    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {}
}

/// Builds a `DetectionEngine` backed by real (temp-directory) stores, with an
/// initial config already applied. Returns the backing directory too, so a
/// test can point a FRESH `CountsStore` at it afterward and assert what
/// actually landed on disk — see `firesThroughTheSinkWithAPostIncrementCount`.
///
/// Deviates from the task brief's literal `let engine = try makeTestEngine()`
/// (unawaited): `DetectionEngine.init` deliberately does NOT read `ConfigStore`
/// itself (see `DetectionEngine.start()`'s doc comment — only an explicit
/// `start()`/`apply(_:)` call loads/applies config, so a test never
/// accidentally starts a real camera), so seeding `sensitivity`/
/// `enabledBehaviors` for a test requires an `await engine.apply(...)` call
/// after construction. `apply(_:)` is an actor-isolated `async` method, so
/// that call cannot be hidden inside a non-async helper — the same shape as
/// `DetectionPolicyTests.swift`'s documented deviation from its own brief,
/// where the verbatim-preserved implementation didn't typecheck against the
/// brief's literal (unawaited) example.
private func makeTestEngine(
    enabledBehaviors: Set<BFRBBehavior> = Set(BFRBBehavior.allCases),
    sensitivity: Double = 0.5
) async throws -> (engine: DetectionEngine, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let config = try ConfigStore(directory: dir)
    let counts = try CountsStore(directory: dir)
    let prefs = try AlertPrefsStore(directory: dir)
    let engine = DetectionEngine(config: config, counts: counts, prefs: prefs, sink: NoopSink())

    var c = VibeCheckConfig.default
    c.sensitivity = sensitivity
    c.enabledBehaviors = enabledBehaviors.map(\.rawValue)
    await engine.apply(c)
    return (engine, dir)
}

// Face box in VIEWER space: top edge at y=0.3, bottom at y=0.7. Nose (0.5, 0.5).
private func face() -> FaceGeometry {
    FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                 nose: CGPoint(x: 0.5, y: 0.5),
                 mouth: CGPoint(x: 0.5, y: 0.62))
}

// MARK: - Tests
//
// These exercise ONLY the detect -> policy -> sink path via
// `ingestForTesting`, which skips the camera and Vision entirely. That is
// deliberate and is the honest limit of what can be unit-tested here — see
// the task report for what this suite does NOT cover (the camera, Vision,
// and the `didOutput` concurrency argument).

@Test func firesThroughTheSinkWithAPostIncrementCount() async throws {
    // The client's notifier asserted the count is post-increment — the first
    // nudge of the day reads "1st", not "0th".
    let (engine, dir) = try await makeTestEngine()
    let sink = SpySink()
    await engine.setSink(sink)

    let hit = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                            face: face())
    await engine.ingestForTesting(hit, at: 0)
    await engine.ingestForTesting(hit, at: 0.2)   // dwell (0.15) satisfied

    let calls = await sink.calls
    #expect(calls.count == 1)
    #expect(calls[0].0 == .nosePicking)
    #expect(calls[0].1 == 1)

    // `fire`'s error-path fallback (`(todayCounts[...] ?? 0) + 1`) also
    // produces 1 on a first detection, so the assertion above cannot tell a
    // genuine `CountsStore.increment` write apart from a completely broken
    // one silently falling back. Point a FRESH `CountsStore` at the same
    // directory — same pattern as `StoreTests.configRoundTripsThroughDisk`
    // — and read back what actually landed on disk.
    let today = CountsStore.dayKey(Date())
    let reloaded = try CountsStore(directory: dir)
    #expect(await reloaded.count(.nosePicking, on: today) == 1)
}

@Test func aDisabledBehaviorNeverReachesTheSink() async throws {
    let (engine, _) = try await makeTestEngine(enabledBehaviors: [])
    let sink = SpySink()
    await engine.setSink(sink)

    let hit = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                            face: face())
    await engine.ingestForTesting(hit, at: 0)
    await engine.ingestForTesting(hit, at: 0.2)

    #expect(await sink.calls.isEmpty)
}

@Test func configChangesTakeEffectWithoutRestart() async throws {
    // The client re-read sensitivity and cooldown every frame so a slider
    // move applied immediately. Preserve that.
    let (engine, _) = try await makeTestEngine(sensitivity: 0.0)   // radius 0.04
    let sink = SpySink()
    await engine.setSink(sink)

    // A fingertip 0.06 away is outside radius 0.04 but inside 0.12.
    let nearMiss = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.56, y: 0.5)]),
                                 face: face())
    await engine.ingestForTesting(nearMiss, at: 0)
    await engine.ingestForTesting(nearMiss, at: 0.2)
    #expect(await sink.calls.isEmpty)

    var c = VibeCheckConfig.default
    c.sensitivity = 1.0
    await engine.apply(c)

    await engine.ingestForTesting(nearMiss, at: 1.0)
    await engine.ingestForTesting(nearMiss, at: 1.2)   // dwell satisfied fresh

    let calls = await sink.calls
    #expect(calls.count == 1)
    #expect(calls[0].0 == .nosePicking)
    #expect(calls[0].1 == 1)
}

@Test func cooldownChangesTakeEffectWithoutRestart() async throws {
    // The brief names both sensitivity AND cooldown as re-read every frame;
    // the previous test only exercised sensitivity. This one holds
    // sensitivity/geometry fixed and varies only cooldown.
    let (engine, _) = try await makeTestEngine()   // default cooldown: 5s
    let sink = SpySink()
    await engine.setSink(sink)

    let hit = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                            face: face())

    // First nudge: dwell (0.15s) satisfied at t=0.2; starts the 5s cooldown.
    await engine.ingestForTesting(hit, at: 0)
    await engine.ingestForTesting(hit, at: 0.2)
    #expect(await sink.calls.count == 1)

    // Still well inside the default 5s cooldown — must stay suppressed.
    // (Dwell re-accumulates from t=0.3 across these two calls, but
    // `DetectionPolicy` does not clear `dwellStart` on a cooldown-blocked
    // frame — see `DetectionPolicyTests.cooldownSuppressesRepeatsOf...` —
    // so it carries forward into the next phase below.)
    await engine.ingestForTesting(hit, at: 0.3)
    await engine.ingestForTesting(hit, at: 0.5)
    #expect(await sink.calls.count == 1)

    // Shrink cooldown live, with sensitivity/enabledBehaviors untouched.
    // 1.0, not e.g. 0.05: `apply(_:)` now clamps (fix #5 of this review
    // round) via `VibeCheckConfig.clamped()`, whose floor for cooldown is 1 —
    // an unclamped 0.05 would silently become 1.0 anyway, which is exactly
    // the divergence-from-disk bug that clamp exists to prevent.
    var c = VibeCheckConfig.default
    c.cooldown = 1.0
    await engine.apply(c)

    // t=1.5: dwell has been continuously satisfied since 0.3 (well past
    // 0.15s — same "dwell already primed" shape `DetectionPolicyTests`
    // documents), and 1.5 - 0.2 = 1.3s clears the shrunk 1.0s cooldown.
    await engine.ingestForTesting(hit, at: 1.5)

    let calls = await sink.calls
    try #require(calls.count == 2)
    #expect(calls[1].1 == 2)
}
