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
/// initial config already applied.
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
) async throws -> DetectionEngine {
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
    return engine
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
    let engine = try await makeTestEngine()
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
}

@Test func aDisabledBehaviorNeverReachesTheSink() async throws {
    let engine = try await makeTestEngine(enabledBehaviors: [])
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
    let engine = try await makeTestEngine(sensitivity: 0.0)   // radius 0.04
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
