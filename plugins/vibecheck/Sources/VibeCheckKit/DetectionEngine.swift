import Foundation

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)`: the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor,
/// and core closes the plugin's stderr pipe during its own shutdown.
private func engineLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// Abstracts what happens to a confirmed detection so `DetectionEngine` can be
/// tested without a live core connection. The production conformer is
/// `HostSink` (see `HostSink.swift`); tests use a spy.
public protocol DetectionSink: Sendable {
    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async
}

/// The engine's whole externally-visible state, as served by `GET /api/state`.
///
/// `permission` is gone. It reported the camera's TCC state, and this plugin
/// no longer opens a camera — the `vision` provider does, and its own
/// `/api/state` is where a camera question is answered now. Reporting a
/// permission this process never asks for would be a field that can only
/// lie. `vision` replaces it with something that is actually true here: what
/// this plugin is asking the provider for, and whether frames are arriving.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public var running: Bool
    public var config: VibeCheckConfig
    public var todayCounts: [String: Int]
    /// Filled in by the `/api/state` route from `VisionFrameJoiner`, which
    /// owns the join and therefore the only honest count of what arrived.
    /// Defaulted so `DetectionEngine.snapshot()` stays a pure read of the
    /// engine's own state and does not have to reach across to another actor.
    public var vision: VisionLinkStats

    public init(running: Bool, config: VibeCheckConfig, todayCounts: [String: Int],
                vision: VisionLinkStats = VisionLinkStats()) {
        self.running = running
        self.config = config
        self.todayCounts = todayCounts
        self.vision = vision
    }
}

/// Turns joined `vision.*` frames into confirmed detections.
///
/// ## What this used to be
///
/// Before the cutover this actor owned the camera, a `VisionLandmarkExtractor`,
/// a 15fps throttle, an MJPEG preview fan-out and a frame SSE fan-out, on top
/// of the detection it does now — 856 lines with four jobs. Losing capture is
/// what made splitting it possible, and the split is by responsibility:
///
///   * `VisionIntake` / `VisionFrameJoiner` — bus intake and the seq join
///   * `VisionRequest`                      — what we ask the provider for
///   * `DetectionEngine`  (this file)       — detect → policy → sink
///   * `HostSink`         (`HostSink.swift`)— alerting, counting, SSE fan-out
///
/// Everything about the camera's concurrency shape went with it. There is no
/// `nonisolated` frame callback here any more, no `nonisolated(unsafe)`
/// property, and no coalescing of overlapping `camera.start()` calls: frames
/// now arrive as ordinary `await`ed calls from `VisionIntake`'s single event
/// loop, so plain actor isolation is the entire concurrency argument.
public actor DetectionEngine {
    private let config: ConfigStore
    private let counts: CountsStore
    private var sink: DetectionSink
    /// Told whenever the config changes, so `vision.request.v1` reflects the
    /// user's actual intent rather than whatever was true at boot. Optional
    /// and attached after construction for the same reason `HostSink.host`
    /// is: routes must be registered before `VCHost.connect()` can be
    /// called, and nothing that needs a live host exists before that.
    private var demand: (any VisionDemandSink)?

    private var detector = BFRBDetector(sensitivity: VibeCheckConfig.default.sensitivity)
    private var policy = DetectionPolicy(dwell: VibeCheckConfig.default.dwell,
                                          cooldown: VibeCheckConfig.default.cooldown)
    /// Live-applied settings. Re-read by `processFrame` on EVERY frame (not
    /// captured once) so a slider move via `apply(_:)` takes effect on the
    /// very next frame.
    private var cachedConfig: VibeCheckConfig = .default

    /// See `nextApplyGeneration()`/`apply(_:generation:)`: `applyGeneration`
    /// is the counter those mint from; `latestAppliedGeneration` is the
    /// highest generation `apply(_:generation:)` has actually committed.
    private var applyGeneration = 0
    private var latestAppliedGeneration = 0

    /// Post-cutover this means exactly "detection is switched on", which is
    /// also exactly what makes this plugin publish a non-empty
    /// `vision.request.v1`. It no longer carries a second meaning about
    /// hardware — whether a camera is actually open is the provider's
    /// business and the provider's `/api/state`.
    private var running = false

    /// Mirrors on-disk counts so `snapshot()` can stay synchronous (no
    /// `await` needed to read `CountsStore`, which is itself an actor).
    /// Seeded from disk in `start()`, kept current by `fire(_:)` on every
    /// confirmed detection. `snapshot()` itself compares `cachedDay` against
    /// today before returning this, so a day rollover with zero detections
    /// since the last `start()`/`fire()` — the common case for a long-running
    /// daemon idle at midnight — reports zeros instead of yesterday's stale
    /// counts; see `snapshot()`.
    private var todayCounts: [String: Int] = [:]
    private var cachedDay = ""

    /// Monotonic reference point for policy time. A `ContinuousClock.Instant`,
    /// not `Date`, because `Date`/`.timeIntervalSinceReferenceDate` is a wall
    /// clock: an NTP/manual clock adjustment can make `time` go backwards
    /// between two frames, producing a negative delta that defeats
    /// `DetectionPolicy`'s cooldown (a cooldown check is `time - last <
    /// cooldown`; a negative `time - last` is always `< cooldown`, so a
    /// clock-back jump would suppress every future alert until real time
    /// caught back up to the old wall-clock value).
    ///
    /// This matters MORE after the cutover, not less: `VisionFrame.ts` is
    /// now another process's wall clock, so using it for a duration would
    /// mean trusting clock agreement across a process boundary as well as
    /// across time. It stays a diagnostic timestamp and nothing else.
    private let clockEpoch = ContinuousClock.now

    public init(config: ConfigStore, counts: CountsStore, sink: DetectionSink) {
        self.config = config
        self.counts = counts
        self.sink = sink
    }

    // MARK: - Lifecycle

    /// Full boot: loads the persisted config and today's counts, then tells
    /// the request publisher what that config implies.
    ///
    /// The pre-cutover version of this opened the camera when the loaded
    /// config said `enabled`, and was careful never to do so otherwise
    /// because `camera.start()` is what triggers the TCC prompt. The
    /// equivalent care now costs nothing to take and is still worth naming:
    /// a fresh install with detection off publishes `{topics: []}`, so it
    /// contributes nothing to the provider's union and no camera opens on
    /// its account.
    public func start() async {
        cachedConfig = await config.load()
        running = cachedConfig.enabled
        await loadTodayCounts()
        await demand?.configChanged(cachedConfig)
    }

    /// Called once, from `main.swift`, right after `VCHost.connect()`.
    public func attach(demand: any VisionDemandSink) {
        self.demand = demand
    }

    /// Stops detecting. Retracting the vision request is `VisionRequest
    /// .retract()`'s job and is registered as its own shutdown hook — this
    /// one only makes sure that a frame still in flight when SIGTERM lands
    /// cannot fire an alert on the way down.
    public func stop() {
        running = false
        cachedConfig.enabled = false
    }

    /// Applies a new config live. Sensitivity/dwell/cooldown/enabledBehaviors
    /// take effect on the very next frame via `cachedConfig` (see its doc).
    /// `enabled` is different in kind — it is a start/stop instruction, not a
    /// per-frame tuning value — and post-cutover BOTH kinds feed the same
    /// place: `demand.configChanged` recomputes `vision.request.v1`, which
    /// is what actually turns the provider's models (and, when every
    /// consumer has retracted, the camera) on and off.
    ///
    /// Note what is no longer here: the `startToken`/`queuedStopToken` pair,
    /// and the coalescing of overlapping camera starts. Those existed
    /// because `camera.start()` suspended for an arbitrarily long TCC prompt
    /// and an actor releases isolation across a suspension. Publishing a
    /// request is a deadlined RPC that cannot block on a human, so a
    /// transition is now just a transition.
    ///
    /// Clamps `newConfig` before storing it: `ConfigStore.save` already
    /// clamps, but `apply(_:)` can be called with a value that was never
    /// routed through `save` (or was applied before being persisted), and
    /// `DetectionPolicy`, unlike `BFRBDetector`, does not clamp its own
    /// `dwell`/`cooldown` — an out-of-range value here would reach it as-is.
    public func apply(_ newConfig: VibeCheckConfig) async {
        let clamped = newConfig.clamped()
        let previous = cachedConfig
        cachedConfig = clamped
        running = clamped.enabled
        guard VisionRequest.topics(for: previous) != VisionRequest.topics(for: clamped) else { return }
        await demand?.configChanged(clamped)
    }

    /// Reserves the next generation number for a live-apply that will
    /// happen LATER, from a detached `Task` — see `apply(_:generation:)`'s
    /// doc comment for the whole reason this pair exists. MUST be called
    /// synchronously at the HTTP handler call site, before that handler
    /// spawns the detached `Task`, and NOT from inside the detached
    /// `Task`'s own body: capturing it there, before detaching, is what
    /// ties the number to REQUEST ARRIVAL order rather than to whatever
    /// order the detached `Task`s happen to be scheduled in. Handlers on
    /// one keep-alive connection are already strictly ordered up to the
    /// point each one RETURNS (`VCHTTPServer`'s `lastRequestTask`
    /// chaining), so calling this before a handler returns — regardless of
    /// exactly where in its body — is enough to make the minted numbers
    /// match request order for same-connection requests.
    public func nextApplyGeneration() -> Int {
        applyGeneration += 1
        return applyGeneration
    }

    /// Same effect as `apply(_:)`, but ignores this call entirely if a
    /// NEWER generation has already been committed — i.e. if a later
    /// request's `apply` reached this actor first.
    ///
    /// `/api/config` PUT and `/api/config/disable` respond before applying
    /// live, then run `engine.apply(saved, generation:)` in a DETACHED
    /// `Task`, so two requests on one keep-alive connection spawn two
    /// INDEPENDENT `Task`s with no ordering relative to each other.
    /// `apply(_:)` unconditionally overwrites `cachedConfig` before checking
    /// for a transition, so if the two detached calls reach this actor out
    /// of request order the OLDER request finishing LAST would clobber the
    /// newer one's config — disk saying `enabled:false` while the engine
    /// runs with `enabled:true`.
    ///
    /// The guard `generation >= latestAppliedGeneration` closes that: only
    /// the highest generation seen so far is ever allowed to commit, so a
    /// stale, out-of-order call is a silent no-op instead of a clobber.
    public func apply(_ newConfig: VibeCheckConfig, generation: Int) async {
        guard generation >= latestAppliedGeneration else {
            engineLog("apply(generation: \(generation)) superseded by generation \(latestAppliedGeneration); ignored")
            return
        }
        latestAppliedGeneration = generation
        await apply(newConfig)
    }

    /// Synchronous by contract (no `await` inside), so it cannot re-fetch
    /// `CountsStore` live. Instead it checks whether its own `cachedDay`
    /// mirror is still today; if midnight has passed since the last
    /// `start()`/`fire()`, the mirror is for yesterday and is NOT returned —
    /// a zeroed dict is, with the same key set `loadTodayCounts` seeds (all
    /// three behaviors), so a caller never sees the shape of `todayCounts`
    /// change across midnight.
    ///
    /// `vision` is left at its default here and filled in by the `/api/state`
    /// route, which can reach the joiner. Deriving `requestedTopics` from
    /// `cachedConfig` instead would risk two answers to one question; the
    /// route asks the actor that actually holds the subscription rule.
    public func snapshot() -> EngineSnapshot {
        let today = CountsStore.dayKey(Date())
        let counts = (today == cachedDay) ? todayCounts : Self.zeroedCounts()
        return EngineSnapshot(running: running, config: cachedConfig, todayCounts: counts)
    }

    private static func zeroedCounts() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: BFRBBehavior.allCases.map { ($0.rawValue, 0) })
    }

    /// Test-support entry point. Production code never calls this.
    public func setSink(_ newSink: DetectionSink) {
        sink = newSink
    }

    // MARK: - Detection

    /// One complete, joined capture frame from `VisionIntake`. Never called
    /// with a partial set — that is `VisionFrameJoiner`'s guarantee, and the
    /// reason it exists.
    public func ingest(_ frame: VisionFrame) async {
        await processFrame(frame, policyTime: monotonicSeconds())
    }

    /// Test-support entry point: runs the detect -> policy -> sink path with
    /// an injected time, skipping the bus entirely.
    public func ingestForTesting(_ frame: VisionFrame, at time: TimeInterval) async {
        await processFrame(frame, policyTime: time)
    }

    /// Shared by the real bus path and `ingestForTesting`, so both take
    /// the identical detect -> policy -> sink path — the only thing that
    /// differs between them is where `policyTime` comes from.
    private func processFrame(_ frame: VisionFrame, policyTime: TimeInterval) async {
        // A frame can arrive while detection is switched off: the provider
        // publishes to every subscriber of a topic SOMEONE asked for, and
        // this plugin stays subscribed (and its process up) whether or not
        // the user wants it detecting. Before the cutover the camera being
        // closed made this structurally impossible; now the guard has to be
        // explicit, or turning detection off would keep firing alerts.
        guard cachedConfig.enabled else { return }

        // Re-read every frame — see `cachedConfig`'s doc comment.
        detector.sensitivity = cachedConfig.sensitivity
        policy.dwell = cachedConfig.dwell
        policy.cooldown = cachedConfig.cooldown
        let enabled = Set(cachedConfig.enabledBehaviors.compactMap(BFRBBehavior.init(rawValue:)))

        let result = detector.detect(frame, enabled: enabled)
        guard let event = policy.ingest(result, at: policyTime) else { return }
        await fire(event)
    }

    private func monotonicSeconds() -> TimeInterval {
        Self.seconds(ContinuousClock.now - clockEpoch)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Confirmed detections

    private func fire(_ event: BFRBEvent) async {
        let day = CountsStore.dayKey(Date())
        if cachedDay != day {
            // Crossed midnight (or this is the very first fire): the local
            // mirror is for a stale day and must not be blended with today's.
            // Same zeroed shape as `loadTodayCounts`/`snapshot()`'s fallback.
            todayCounts = Self.zeroedCounts()
            cachedDay = day
        }

        let count: Int
        do {
            count = try await counts.increment(event.behavior, on: day)
        } catch {
            // A store write failure is not a reason to drop the detection —
            // fall back to the local mirror so the sink still sees a sane,
            // monotonically increasing count for this session.
            engineLog("counts store increment failed: \(error)")
            count = (todayCounts[event.behavior.rawValue] ?? 0) + 1
        }
        todayCounts[event.behavior.rawValue] = count

        await sink.fired(event, count: count, behavior: event.behavior)
    }

    private func loadTodayCounts() async {
        let day = CountsStore.dayKey(Date())
        var loaded: [String: Int] = [:]
        for behavior in BFRBBehavior.allCases {
            loaded[behavior.rawValue] = await counts.count(behavior, on: day)
        }
        todayCounts = loaded
        cachedDay = day
    }
}
