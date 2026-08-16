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

/// Records what the engine asks the request publisher for, without the
/// publisher (or a bus) existing.
private actor SpyDemand: VisionDemandSink {
    private(set) var configs: [VibeCheckConfig] = []
    func configChanged(_ config: VibeCheckConfig) async {
        configs.append(config)
    }
    var topics: [Set<VisionTopic>] { configs.map(VisionRequest.topics(for:)) }
}

/// Builds a `DetectionEngine` backed by real (temp-directory) stores, with an
/// initial config already applied. Returns the backing directory too, so a
/// test can point a FRESH `CountsStore` at it afterward and assert what
/// actually landed on disk — see `firesThroughTheSinkWithAPostIncrementCount`.
///
/// `enabled: true` throughout, which the pre-cutover version of this helper
/// could not do: `apply(enabled: true)` used to call `camera.start()` and hit
/// real AVFoundation/TCC inside `swift test`. Nothing here opens a camera any
/// more — the engine's only reaction to `enabled` is recomputing what it asks
/// the vision provider for — so the tests can finally use the config a real
/// detecting user has, which is what `processFrame`'s `cachedConfig.enabled`
/// guard requires them to use.
private func makeTestEngine(
    enabledBehaviors: Set<BFRBBehavior> = Set(BFRBBehavior.allCases),
    sensitivity: Double = 0.5,
    enabled: Bool = true
) async throws -> (engine: DetectionEngine, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let config = try ConfigStore(directory: dir)
    let counts = try CountsStore(directory: dir)
    let engine = DetectionEngine(config: config, counts: counts, sink: NoopSink())

    var c = VibeCheckConfig.default
    c.enabled = enabled
    c.sensitivity = sensitivity
    c.enabledBehaviors = enabledBehaviors.map(\.rawValue)
    await engine.apply(c)
    return (engine, dir)
}

// Face box in VIEWER space: top edge at y=0.3, bottom at y=0.7. Nose (0.5, 0.5).
private let faceBox = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)

private func hit() -> VisionFrame {
    Fixtures.frame(box: faceBox, nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62),
                   fingertips: [CGPoint(x: 0.5, y: 0.5)])
}

// MARK: - Tests
//
// These exercise ONLY the detect -> policy -> sink path via
// `ingestForTesting`, which skips the bus entirely. The join that produces a
// `VisionFrame` in production has its own suite (`VisionIntakeTests`).

@Test func firesThroughTheSinkWithAPostIncrementCount() async throws {
    // The client's notifier asserted the count is post-increment — the first
    // nudge of the day reads "1st", not "0th".
    let (engine, dir) = try await makeTestEngine()
    let sink = SpySink()
    await engine.setSink(sink)

    await engine.ingestForTesting(hit(), at: 0)
    await engine.ingestForTesting(hit(), at: 0.2)   // dwell (0.15) satisfied

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

    await engine.ingestForTesting(hit(), at: 0)
    await engine.ingestForTesting(hit(), at: 0.2)

    #expect(await sink.calls.isEmpty)
}

// New guard, and the cutover is what made it necessary. Before, the camera
// being closed made "a frame arrives while detection is off" structurally
// impossible. Now the provider publishes to every subscriber of a topic
// SOMEONE asked for, and this plugin stays subscribed (and its process up)
// whether or not the user wants it detecting — so without an explicit check,
// turning detection off would keep firing alerts off another consumer's
// frames.
@Test func aFrameArrivingWhileDetectionIsOffIsIgnored() async throws {
    let (engine, _) = try await makeTestEngine(enabled: false)
    let sink = SpySink()
    await engine.setSink(sink)

    await engine.ingestForTesting(hit(), at: 0)
    await engine.ingestForTesting(hit(), at: 0.2)

    #expect(await sink.calls.isEmpty)
    #expect(await engine.snapshot().running == false)
}

@Test func configChangesTakeEffectWithoutRestart() async throws {
    // The client re-read sensitivity and cooldown every frame so a slider
    // move applied immediately. Preserve that.
    let (engine, _) = try await makeTestEngine(sensitivity: 0.0)   // radius 0.04
    let sink = SpySink()
    await engine.setSink(sink)

    // A fingertip 0.06 away is outside radius 0.04 but inside 0.12.
    let nearMiss = Fixtures.frame(box: faceBox, nose: CGPoint(x: 0.5, y: 0.5),
                                  mouth: CGPoint(x: 0.5, y: 0.62),
                                  fingertips: [CGPoint(x: 0.56, y: 0.5)])
    await engine.ingestForTesting(nearMiss, at: 0)
    await engine.ingestForTesting(nearMiss, at: 0.2)
    #expect(await sink.calls.isEmpty)

    var c = VibeCheckConfig.default
    c.enabled = true
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

    // First nudge: dwell (0.15s) satisfied at t=0.2; starts the 5s cooldown.
    await engine.ingestForTesting(hit(), at: 0)
    await engine.ingestForTesting(hit(), at: 0.2)
    #expect(await sink.calls.count == 1)

    // Still well inside the default 5s cooldown — must stay suppressed.
    // (Dwell re-accumulates from t=0.3 across these two calls, but
    // `DetectionPolicy` does not clear `dwellStart` on a cooldown-blocked
    // frame — see `DetectionPolicyTests.cooldownSuppressesRepeatsOf...` —
    // so it carries forward into the next phase below.)
    await engine.ingestForTesting(hit(), at: 0.3)
    await engine.ingestForTesting(hit(), at: 0.5)
    #expect(await sink.calls.count == 1)

    // Shrink cooldown live, with sensitivity/enabledBehaviors untouched.
    // 1.0, not e.g. 0.05: `apply(_:)` clamps via `VibeCheckConfig.clamped()`,
    // whose floor for cooldown is 1 — an unclamped 0.05 would silently
    // become 1.0 anyway, which is exactly the divergence-from-disk bug that
    // clamp exists to prevent.
    var c = VibeCheckConfig.default
    c.enabled = true
    c.cooldown = 1.0
    await engine.apply(c)

    // t=1.5: dwell has been continuously satisfied since 0.3 (well past
    // 0.15s — same "dwell already primed" shape `DetectionPolicyTests`
    // documents), and 1.5 - 0.2 = 1.3s clears the shrunk 1.0s cooldown.
    await engine.ingestForTesting(hit(), at: 1.5)

    let calls = await sink.calls
    try #require(calls.count == 2)
    #expect(calls[1].1 == 2)
}

// MARK: - The engine drives the vision request

@Test func startPublishesWhateverThePersistedConfigImplies() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try ConfigStore(directory: dir)
    var persisted = VibeCheckConfig.default
    persisted.enabled = true
    persisted.enabledBehaviors = [BFRBBehavior.nailBiting.rawValue]
    try await store.save(persisted)

    let engine = DetectionEngine(config: store, counts: try CountsStore(directory: dir), sink: NoopSink())
    let demand = SpyDemand()
    await engine.attach(demand: demand)
    await engine.start()

    // A fresh install with detection OFF must contribute nothing to the
    // provider's union, so this has to be driven by what is on disk and not
    // by a hardcoded boot value.
    #expect(await demand.topics == [[.face, .hands]])
    #expect(await engine.snapshot().running == true)
}

@Test func aConfigChangeThatCannotChangeTheTopicSetDoesNotRepublish() async throws {
    // Dragging the sensitivity slider must not put a message on the bus per
    // pixel. `apply` compares the topic sets, not the configs.
    let (engine, _) = try await makeTestEngine()
    let demand = SpyDemand()
    await engine.attach(demand: demand)

    var c = VibeCheckConfig.default
    c.enabled = true
    c.sensitivity = 0.9
    await engine.apply(c)
    #expect(await demand.configs.isEmpty)

    c.enabled = false
    await engine.apply(c)
    #expect(await demand.topics == [[]])
}

@Test func stopMakesTheEngineRefuseFramesStillInFlight() async throws {
    let (engine, _) = try await makeTestEngine()
    let sink = SpySink()
    await engine.setSink(sink)

    await engine.stop()
    await engine.ingestForTesting(hit(), at: 0)
    await engine.ingestForTesting(hit(), at: 0.2)

    #expect(await sink.calls.isEmpty)
    #expect(await engine.snapshot().running == false)
}

// MARK: - apply(_:generation:) — "the last request issued wins"
//
// `/api/config` PUT and `/api/config/disable` respond before applying live,
// then run `engine.apply(saved, generation:)` in a DETACHED `Task` (awaiting
// `apply` inline could block the HTTP response, and with it every later
// request queued behind it on the same keep-alive connection). Detaching
// removed an ordering guarantee that used to hold for free: two requests on
// one keep-alive connection now spawn two INDEPENDENT `Task`s with no
// ordering relative to each other, and `apply(_:)` unconditionally
// overwrites `cachedConfig` — so if the two detached calls reach the actor
// out of request order, the OLDER request finishing LAST would clobber the
// newer one's config.

@Test func aStaleGenerationArrivingLastIsIgnoredNotAppliedInOrderOfArrival() async throws {
    let (engine, _) = try await makeTestEngine()

    // Reserve BOTH generations up front, exactly like two HTTP handlers
    // would (each calls `nextApplyGeneration()` synchronously, before
    // detaching) — genA is minted first (the earlier request), genB second
    // (the later one).
    let genA = await engine.nextApplyGeneration()
    let genB = await engine.nextApplyGeneration()
    #expect(genB > genA)

    var configA = VibeCheckConfig.default
    configA.sensitivity = 0.9
    var configB = VibeCheckConfig.default
    configB.sensitivity = 0.2

    // Completion order is the INVERSE of request order — the later
    // request's detached apply (genB) reaches the actor and commits
    // FIRST, exactly the interleaving a slow publish on the earlier
    // request would produce.
    await engine.apply(configB, generation: genB)
    await engine.apply(configA, generation: genA)   // stale — must be ignored

    let snap = await engine.snapshot()
    #expect(snap.config.sensitivity == 0.2)   // genB's value, not clobbered by stale genA
}

@Test func generationsCommittingInOrderApplyNormally() async throws {
    let (engine, _) = try await makeTestEngine()

    let gen1 = await engine.nextApplyGeneration()
    var c1 = VibeCheckConfig.default
    c1.sensitivity = 0.3
    await engine.apply(c1, generation: gen1)
    #expect(await engine.snapshot().config.sensitivity == 0.3)

    let gen2 = await engine.nextApplyGeneration()
    var c2 = VibeCheckConfig.default
    c2.sensitivity = 0.7
    await engine.apply(c2, generation: gen2)
    #expect(await engine.snapshot().config.sensitivity == 0.7)
}
