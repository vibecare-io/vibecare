import CoreVideo
import Foundation
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — same rule and same
/// reason as `CameraSession.swift` / `VisionLandmarkExtractor.swift` /
/// `VCPluginSDK/VCLog.swift`: the `FileHandle` overload raises an
/// *uncatchable* `NSException` on a closed descriptor, and core closes the
/// plugin's stderr pipe during its own shutdown.
private func engineLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// See `didOutput`'s use of this for why it exists: a `@unchecked Sendable`
/// wrapper that lets a `CVPixelBuffer` cross into an unstructured `Task`
/// despite the compiler's region-based "sending" check being unable to
/// prove that's safe on its own.
private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Abstracts what happens to a confirmed detection so `DetectionEngine` can be
/// tested without a live core connection. Mirrors the client's
/// `DetectionNotifying` seam (`VibeCheckViewModel.swift`). The production
/// conformer is `HostSink`; tests use a spy.
public protocol DetectionSink: Sendable {
    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async
}

/// The engine's whole externally-visible state, as served by `GET /api/state`
/// (Task 15). `permission` is a string rather than `CameraStartResult`
/// because "never asked yet" (`unknown`) has no `CameraStartResult` case —
/// the camera hasn't been asked to start at all, which is not the same as a
/// `.denied` answer.
public struct EngineSnapshot: Codable, Sendable, Equatable {
    public var running: Bool
    public var permission: String        // "granted" | "denied" | "noDevice" | "unknown"
    public var config: VibeCheckConfig
    public var todayCounts: [String: Int]

    public init(running: Bool, permission: String, config: VibeCheckConfig, todayCounts: [String: Int]) {
        self.running = running
        self.permission = permission
        self.config = config
        self.todayCounts = todayCounts
    }
}

/// The actor that replaces `VibeCheckViewModel`: owns the camera, throttles
/// and runs Vision, feeds `BFRBDetector`/`DetectionPolicy`, and hands
/// confirmed detections to a `DetectionSink`.
///
/// ## Concurrency shape (read this before touching `didOutput`)
///
/// `VisionLandmarkExtractor.analyze` is NOT concurrency-safe — its stored
/// `VNRequest`s are reference types whose `.results` are overwritten by each
/// call, so two concurrent `analyze` calls (even through separate `struct`
/// copies bound to the same underlying request objects — here there's only
/// one `extractor` value, so it's the same objects, full stop) would
/// cross-contaminate. `CameraSession` guarantees its delegate callback
/// (`captureOutput` -> `receiver?.didOutput`) is invoked serially, always on
/// the same private `frameQueue` (see `CameraSession.configure()`:
/// `output.setSampleBufferDelegate(self, queue: frameQueue)`, where
/// `frameQueue` is a single, non-concurrent `DispatchQueue`). `didOutput`
/// below is `nonisolated` — it does NOT hop onto the actor — specifically so
/// that `extractor.analyze(...)` keeps running on that same serial
/// `frameQueue`, synchronously, exactly like it did for the client's single
/// `frameQueue`-confined `didOutput`. The actor is only entered *after*
/// `analyze` has already produced an immutable `LandmarkFrame`, via
/// `Task { await self.consume(frame) }` — so the actor never needs to
/// serialize `analyze` itself; `CameraSession`'s own serial queue already did.
///
/// This is the same confinement argument the client's view model made with
/// `nonisolated(unsafe) private let extractor` — see that type's comment. The
/// three `nonisolated(unsafe)` properties below exist for the identical
/// reason: they are read and written ONLY from `didOutput`, which is only
/// ever invoked on `frameQueue`, so there is no concurrent access to guard
/// against even though the compiler cannot prove it. Nothing here makes a
/// type-wide `Sendable` claim about `VisionLandmarkExtractor` or `CVPixelBuffer`
/// — it documents that these specific properties, used this specific way, are safe.
public actor DetectionEngine: CameraFrameReceiver {
    /// Minimum spacing between two Vision analyses, applied in `didOutput`
    /// BEFORE `extractor.analyze` runs so a discarded frame costs nothing —
    /// preserved verbatim from `VibeCheckViewModel.didOutput`.
    private static let minInterval: TimeInterval = 1.0 / 15.0

    /// `CameraSession` isn't `Sendable` (see its own file for why:
    /// `AVCaptureSession` is only `@unchecked Sendable` there under a manual
    /// synchronization argument). `nonisolated(unsafe)` asserts only that
    /// *this* reference is safe to use across the actor boundary the way this
    /// type uses it — `didOutput` below (nonisolated, confined to
    /// `frameQueue`) never touches `camera` itself, only receives callbacks
    /// from it, so there is no race there. It is NOT true that
    /// `start()`/`stop()`/`apply()` can only reach `camera.start()`
    /// sequentially: actor isolation is released across `await
    /// camera.start()`'s suspension, so two of those calls CAN interleave.
    /// What actually prevents a double `camera.start()` is
    /// `startCameraOnly()`'s `cameraStartTask` coalescing guard, not this
    /// property's annotation — see that method's doc comment. Same
    /// `nonisolated(unsafe)` reasoning, same annotation, as
    /// `VibeCheckViewModel.camera` in the client this replaces.
    public nonisolated(unsafe) let camera = CameraSession()

    /// See the type-level doc comment: touched only on `CameraSession`'s
    /// private serial `frameQueue`, via `didOutput`, never concurrently with
    /// itself and never from the actor.
    nonisolated(unsafe) private let extractor = VisionLandmarkExtractor()
    /// Throttle reference point. A `ContinuousClock.Instant`, NOT `Date` —
    /// `Date`/wall-clock comparison is exactly the defect this engine's
    /// `monotonicSeconds()` was built to avoid for policy time, and it
    /// applies here too: a backward wall-clock step of N seconds would make
    /// `ts.timeIntervalSince(lastAnalysis)` negative for every frame until
    /// real time caught back up, so the throttle's `>= minInterval` check
    /// would never pass and every frame would be silently discarded for N
    /// seconds — detection dead with no log line. `nil` until the first
    /// frame. Same confinement as `extractor`.
    nonisolated(unsafe) private var lastAnalysisInstant: ContinuousClock.Instant?
    /// Monotonic per-frame counter, incremented for every RAW camera frame —
    /// including ones the throttle below discards — so gaps in the sequence
    /// a downstream consumer sees are evidence of exactly which frames were
    /// dropped. Same confinement as `extractor`.
    nonisolated(unsafe) private var seqUnsafe: UInt64 = 0

    private let config: ConfigStore
    private let counts: CountsStore
    private var sink: DetectionSink

    /// `/preview.mjpeg`'s whole frame source. `nil` in every existing test
    /// (and safe to leave `nil` there): `CameraSession.receiver` is a single
    /// slot, already claimed by this engine for Vision analysis, so the raw
    /// pixel buffer has to be re-forwarded from here rather than have
    /// `PreviewStream` attach to the camera independently. Fed EVERY raw
    /// frame in `didOutput`, deliberately before the Vision throttle below —
    /// see `PreviewStream.publish`'s own doc comment for why its cadence is
    /// independent of, and looser than, Vision's 15fps gate.
    public nonisolated let previewStream: PreviewStream?

    private var detector = BFRBDetector(sensitivity: VibeCheckConfig.default.sensitivity)
    private var policy = DetectionPolicy(dwell: VibeCheckConfig.default.dwell,
                                          cooldown: VibeCheckConfig.default.cooldown)
    /// Live-applied settings. Re-read by `processFrame` on EVERY frame (not
    /// captured once) so a slider move via `apply(_:)` takes effect on the
    /// very next frame, exactly like `VibeCheckViewModel.consume` re-read its
    /// own `@Published` `sensitivity`/`alertInterval` every call.
    private var cachedConfig: VibeCheckConfig = .default

    /// See `nextApplyGeneration()`/`apply(_:generation:)`: `applyGeneration`
    /// is the counter those mint from; `latestAppliedGeneration` is the
    /// highest generation `apply(_:generation:)` has actually committed.
    private var applyGeneration = 0
    private var latestAppliedGeneration = 0

    private var running = false
    private var permission = "unknown"   // "granted" | "denied" | "noDevice" | "unknown"

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
    /// caught back up to the old wall-clock value). `LandmarkFrame.ts` stays
    /// wall-clock `Date` deliberately — it is a timestamp for external
    /// consumption, not a duration this engine reasons about.
    private let clockEpoch = ContinuousClock.now

    /// Fan-out for `frames()`, mirroring `VCHost.events()`'s continuation-map
    /// pattern.
    private var frameContinuations: [UUID: AsyncStream<LandmarkFrame>.Continuation] = [:]

    /// Coalesces overlapping `camera.start()` attempts — see
    /// `startCameraOnly()`'s doc comment for why this exists at all. A plain
    /// `Bool` (not a `Task` handle): wrapping `camera.start()` in a child
    /// `Task` to hand out a shareable future would capture `camera` — a
    /// non-`Sendable`, actor-stored `nonisolated(unsafe)` reference — into a
    /// `@Sendable` closure, which the compiler correctly refuses even though
    /// the manual-synchronization argument for `camera` holds; calling
    /// `camera.start()` directly, in place, inside this already-`async`
    /// actor method sidesteps that without needing a second unsafe
    /// annotation to justify it.
    private var cameraStartInFlight = false
    /// Actor-isolated callers that arrived while `cameraStartInFlight` was
    /// already `true`; released with the real result once the in-flight
    /// call returns. Same shape as `VCShutdownLatch` in `VCPluginSDK`.
    private var cameraStartWaiters: [CheckedContinuation<CameraStartResult, Never>] = []
    /// Bumped on EVERY call to `startCameraOnly()` — the leader that
    /// actually calls `camera.start()` AND any waiter that merely parks on
    /// an already in-flight call (there is only ever one real
    /// `camera.start()` in flight at a time, by this method's own
    /// coalescing guard, so a waiter's arrival is still a fresh, distinct
    /// "start" intent even though it doesn't become the leader). This is
    /// what a stop can be compared against to tell "was I superseded by a
    /// later start request" apart from "no one has asked to start since
    /// me" — see `queuedStopToken`'s doc comment for why a plain `Bool`
    /// version of this got that distinction wrong.
    private var startToken: Int = 0
    /// Set by `stop()`, to the CURRENT `startToken` value, when it arrives
    /// while `cameraStartInFlight` is `true`. Compared against `startToken`
    /// again (not merely checked for non-nil) at the in-flight start's
    /// completion: `queued == startToken` means "no start request has
    /// arrived since this stop was queued," in which case the stop wins;
    /// `queued != startToken` means a later `startCameraOnly()` call
    /// (leader or waiter) has expressed fresher intent to start, which
    /// supersedes the stale stop.
    ///
    /// A first version of this used a bare `Bool` instead, set by `stop()`
    /// and cleared only by the LEADER's own completion. Review caught the
    /// bug that shape has: if a stop raced an in-flight start, and then a
    /// SECOND start request arrived (and, since only one `camera.start()`
    /// can be in flight at a time, parked as a WAITER on the very same
    /// in-flight call rather than becoming a new leader), the waiter's
    /// arrival never touched the bool — so when the original start finally
    /// resolved, the stale "please stop" from before the second request
    /// still won, leaving `config.enabled == true` but the camera off and
    /// `running == false`, with no further start ever issued (`apply` only
    /// acts on a *transition*). Comparing tokens instead of a bool fixes
    /// this: the waiter's arrival bumps `startToken`, which immediately
    /// invalidates the earlier `queuedStopToken` recorded before it.
    private var queuedStopToken: Int?

    public init(config: ConfigStore, counts: CountsStore, sink: DetectionSink,
                previewStream: PreviewStream? = nil) {
        self.config = config
        self.counts = counts
        self.sink = sink
        self.previewStream = previewStream
    }

    // MARK: - Lifecycle

    /// Full boot: loads the persisted config and today's counts, then opens
    /// the camera ONLY if the loaded config says `enabled`. This is the
    /// affirmative half of "the camera is gated on `config.enabled` alone"
    /// (the negative half — never gate on `_core.demand.v1` — is documented
    /// on `apply(_:)`): a fresh install with detection off must never trigger
    /// the TCC camera-permission prompt, and `camera.start()` is exactly what
    /// triggers it. Safe to call again later (e.g. after the user enables
    /// detection through some path other than `apply(_:)`) — it always
    /// reloads `cachedConfig` from disk first, so it reflects whatever is
    /// current, not whatever this engine last cached.
    @discardableResult
    public func start() async -> CameraStartResult {
        cachedConfig = await config.load()
        await loadTodayCounts()
        guard cachedConfig.enabled else {
            // `.denied` is repurposed here as "no camera access obtained" —
            // it is what a caller checking only this return value needs, and
            // is not distinguishable from a real TCC denial through this
            // value alone. The distinction IS available via `snapshot()`:
            // `config.enabled == false` with `permission` left at "unknown"
            // (never asked) means "off by choice," not "asked and refused."
            return .denied
        }
        return await startCameraOnly()
    }

    /// Tells the camera to stop and reports `running = false` immediately —
    /// even while a `startCameraOnly()` call is suspended inside `await
    /// camera.start()` for this very engine. See `queuedStopToken` and
    /// `startCameraOnly()`'s completion below for the other half of this
    /// fix: without it, a `stop()` that races an in-flight start sets
    /// `running = false` here, then gets silently clobbered back to `true`
    /// (and the camera left running) the moment the in-flight `camera.start()`
    /// call resolves — a caller who just asked to turn detection off, mid-
    /// start, would see `/api/state` report `running: true` and the camera
    /// hardware still active. That is a real, user-triggerable race through
    /// this task's own wiring: `PUT /api/config` with `enabled: false` calls
    /// `apply(_:)` -> `stop()`, and can land while `start()` (called once,
    /// unawaited, from main.swift's boot sequence) is still awaiting
    /// `camera.start()`'s TCC prompt.
    public func stop() async {
        if cameraStartInFlight {
            queuedStopToken = startToken
        }
        // Told eagerly either way — no reason to wait for the in-flight
        // start to resolve before asking AVFoundation to shut down; `stop()`
        // on `CameraSession` is itself idempotent (gated on
        // `session.isRunning`), so calling it again from
        // `startCameraOnly()`'s completion once `queuedStopToken` is found
        // to still apply costs nothing.
        camera.stop()
        running = false
    }

    /// Applies a new config live. Sensitivity/dwell/cooldown/enabledBehaviors
    /// take effect on the very next frame via `cachedConfig` (see its doc).
    /// `enabled` is different in kind — it is a start/stop instruction, not a
    /// per-frame tuning value — so a transition in it (either direction)
    /// drives the camera directly. This is the ONLY thing that gates the
    /// camera: not `_core.demand.v1` subscriber counts (this plugin publishes
    /// `vibecheck.behavior_detected.v1`, which nothing in-tree subscribes to,
    /// so that count is structurally 0 forever — gating on it would mean the
    /// camera never opens). The reserved zero-demand rule belongs to
    /// `sensor.landmarks.v1` (a later task), not here.
    ///
    /// Deliberately calls `startCameraOnly()`, not `start()`: `start()`
    /// reloads `cachedConfig` from disk, which would be redundant with (and,
    /// if the caller applies a config it hasn't persisted yet, would clobber)
    /// the config this very call just applied.
    ///
    /// Clamps `newConfig` before storing it: `ConfigStore.save` already
    /// clamps, but `apply(_:)` can be called with a value that was never
    /// routed through `save` (or was applied before being persisted), and
    /// `DetectionPolicy`, unlike `BFRBDetector`, does not clamp its own
    /// `dwell`/`cooldown` — an out-of-range value here would reach it as-is.
    public func apply(_ newConfig: VibeCheckConfig) async {
        let clamped = newConfig.clamped()
        let wasEnabled = cachedConfig.enabled
        cachedConfig = clamped
        guard wasEnabled != clamped.enabled else { return }
        if clamped.enabled {
            await startCameraOnly()
        } else {
            await stop()
        }
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
    /// Why this exists: `/api/config` PUT and `/api/config/disable` respond
    /// before applying live, then run `engine.apply(saved, generation:)` in
    /// a DETACHED `Task` (fixed in an earlier review round — see
    /// `API.swift` — because `apply` can block on a real TCC prompt via
    /// `startCameraOnly()`, and that must never hang the HTTP response).
    /// Detaching removed an ordering guarantee that used to hold for free:
    /// two requests on one keep-alive connection — `PUT {enabled:true}`
    /// immediately followed by `POST /api/config/disable`, say — now spawn
    /// two INDEPENDENT `Task`s with no ordering relative to each other.
    /// `apply(_:)` unconditionally overwrites `cachedConfig = clamped`
    /// before even checking for a transition, so if the two detached calls
    /// reach this actor out of request order — entirely plausible, since
    /// the enabling one can be stuck behind a slow TCC prompt while the
    /// disabling one sails through instantly — the OLDER request finishing
    /// LAST would clobber the newer one's config back to a stale value:
    /// disk says `enabled:false` (the disable's write, which always
    /// persists synchronously and correctly) while the engine ends up with
    /// `cachedConfig.enabled == true` and the camera actually started.
    ///
    /// The guard `generation >= latestAppliedGeneration` closes that: only
    /// the highest generation seen so far is ever allowed to commit, so a
    /// stale, out-of-order call is a silent no-op instead of a clobber.
    ///
    /// This is a DIFFERENT race from the one `startToken`/`queuedStopToken`
    /// (see `stop()`/`startCameraOnly()`) guards: that pair orders a
    /// `stop()` against ONE `startCameraOnly()` call already in flight on
    /// THIS actor. This guards which of TWO separately-detached `apply(_:)`
    /// calls' config value is allowed to commit at all, regardless of
    /// whether either has even reached `startCameraOnly()` yet. Both are
    /// needed: this guard alone wouldn't stop a stop() that arrives WHILE
    /// the winning generation's `startCameraOnly()` is already in flight —
    /// that's still `queuedStopToken`'s job.
    public func apply(_ newConfig: VibeCheckConfig, generation: Int) async {
        guard generation >= latestAppliedGeneration else {
            engineLog("apply(generation: \(generation)) superseded by generation \(latestAppliedGeneration); ignored")
            return
        }
        latestAppliedGeneration = generation
        await apply(newConfig)
    }

    /// Coalesces overlapping attempts to start the camera onto a single
    /// in-flight `camera.start()` call, instead of letting each caller issue
    /// its own.
    ///
    /// Why this is needed at all: actor isolation does NOT prevent two
    /// callers from both reaching `camera.start()`. `camera.start()` itself
    /// suspends (it awaits `AVCaptureDevice.requestAccess`/an async
    /// `configure()` path), and an actor releases isolation across a
    /// suspension point — so a boot-time `start()` and an HTTP-driven
    /// `apply(enabled: true)` arriving moments apart can both reach here
    /// before either's underlying `camera.start()` call has returned. Two
    /// overlapping `camera.start()` calls can both observe
    /// `session.inputs.isEmpty` as true and both call `configure()`, which
    /// double-adds inputs/outputs to one `AVCaptureSession` via overlapping
    /// `beginConfiguration`/`commitConfiguration` pairs — that can raise an
    /// uncatchable `NSException` and abort the process, which
    /// `supervisor.go` charges as a failed start. This mirrors the client's
    /// `isTransitioning` guard on `setDetection`, but coalesces onto the
    /// real in-flight result rather than bailing out with a fabricated one,
    /// so every caller — the owner and anyone who arrived while it was
    /// already running — gets the same true `CameraStartResult`.
    @discardableResult
    private func startCameraOnly() async -> CameraStartResult {
        camera.receiver = self
        // Every entry — leader or waiter — is a fresh "start" intent, and
        // bumping this unconditionally (before the in-flight check) is what
        // invalidates a `queuedStopToken` recorded by a `stop()` that
        // arrived before THIS call. See `queuedStopToken`'s doc comment.
        startToken += 1

        if cameraStartInFlight {
            return await withCheckedContinuation { (continuation: CheckedContinuation<CameraStartResult, Never>) in
                cameraStartWaiters.append(continuation)
            }
        }

        cameraStartInFlight = true
        let result = await camera.start()
        cameraStartInFlight = false

        // `permission` always reflects what the OS actually said, even if a
        // stop() below overrides `running` — a caller who stopped mid-start
        // still deserves to know whether permission was granted.
        permission = Self.permissionString(for: result)

        if let queued = queuedStopToken, queued == startToken {
            // A stop() arrived while this start was suspended inside `await
            // camera.start()` above, and NO start request has arrived since
            // (if one had, `startToken` would have moved past `queued` —
            // see that property's doc comment). Honor the stop instead of
            // clobbering it with `result` — even if the camera genuinely
            // did come up, whoever called stop() must see `running ==
            // false` and the camera must end up stopped, not left running
            // because a now-stale start happened to resolve afterward.
            queuedStopToken = nil
            camera.stop()
            running = false
        } else {
            // Either no stop was queued, or one was but a later start
            // superseded it — either way, clear any stale token so it can
            // never accidentally match a future `startToken` value.
            queuedStopToken = nil
            running = (result == .started)
        }

        let waiters = cameraStartWaiters
        cameraStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        return result
    }

    private static func permissionString(for result: CameraStartResult) -> String {
        switch result {
        case .started: return "granted"
        case .denied: return "denied"
        case .noDevice: return "noDevice"
        }
    }

    /// Synchronous by contract (no `await` inside), so it cannot re-fetch
    /// `CountsStore` live. Instead it checks whether its own `cachedDay`
    /// mirror is still today; if midnight has passed since the last
    /// `start()`/`fire()`, the mirror is for yesterday and is NOT returned —
    /// a zeroed dict is, with the same key set `loadTodayCounts` seeds (all
    /// three behaviors), so a caller never sees the shape of `todayCounts`
    /// change across midnight.
    public func snapshot() -> EngineSnapshot {
        let today = CountsStore.dayKey(Date())
        let counts = (today == cachedDay) ? todayCounts : Self.zeroedCounts()
        return EngineSnapshot(running: running, permission: permission, config: cachedConfig, todayCounts: counts)
    }

    private static func zeroedCounts() -> [String: Int] {
        Dictionary(uniqueKeysWithValues: BFRBBehavior.allCases.map { ($0.rawValue, 0) })
    }

    /// Test-support entry point. Production code never calls this.
    public func setSink(_ newSink: DetectionSink) {
        sink = newSink
    }

    // MARK: - Frame fan-out

    public func frames() -> AsyncStream<LandmarkFrame> {
        let (stream, continuation) = AsyncStream<LandmarkFrame>.makeStream(
            of: LandmarkFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let key = UUID()
        frameContinuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.dropFrameContinuation(key) }
        }
        return stream
    }

    private func dropFrameContinuation(_ key: UUID) {
        frameContinuations.removeValue(forKey: key)
    }

    private func publishFrame(_ frame: LandmarkFrame) {
        for continuation in frameContinuations.values {
            continuation.yield(frame)
        }
    }

    // MARK: - Camera -> Vision (nonisolated, confined to frameQueue)

    /// `CameraFrameReceiver` conformance. Runs synchronously on
    /// `CameraSession`'s private serial `frameQueue` — see the type-level doc
    /// comment for why that makes this safe despite `extractor` not being
    /// concurrency-safe on its own.
    ///
    /// `ts` is sampled here, at entry, before the throttle check and before
    /// Vision runs — the earliest point available (`CameraSession` discards
    /// the sample buffer's real presentation timestamp) and the only point
    /// that doesn't fold inference latency into the timestamp. `ts` is used
    /// ONLY for `LandmarkFrame.ts` (an external timestamp) — the throttle
    /// itself is measured against `ContinuousClock`, a monotonic source, so
    /// a wall-clock adjustment cannot defeat it. See `lastAnalysisInstant`'s
    /// doc comment for why a `Date`-based throttle would be exactly the bug
    /// `monotonicSeconds()` exists to avoid for policy time.
    public nonisolated func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool) {
        // Every raw frame, unconditionally, BEFORE the Vision throttle below
        // — `PreviewStream.publish` has its own, independent, looser cadence
        // gate (10fps) and idles for free when nobody is attached, so this
        // never costs anything when no one is watching the preview.
        //
        // `pixelBuffer` is still used below (by `extractor.analyze`), so the
        // compiler's region-based "sending" check refuses to hand the bare
        // variable to an unstructured `Task` — it cannot prove this closure
        // won't race the rest of this function's use of the same buffer.
        // `PixelBufferBox` sidesteps that the same way `CameraSession`'s
        // `AVCaptureSession: @unchecked Sendable` extension does: CVPixelBuffer
        // is a CF reference type, safe to hand to another concurrency domain
        // for a read-only encode, and the box's `@unchecked Sendable`
        // conformance is what lets the closure capture IT instead of the
        // tracked `pixelBuffer` binding.
        if let previewStream {
            let box = PixelBufferBox(buffer: pixelBuffer)
            Task { await previewStream.publish(box.buffer, mirrored: mirrored) }
        }

        let ts = Date()
        seqUnsafe &+= 1
        let seq = seqUnsafe

        let now = ContinuousClock.now
        if let last = lastAnalysisInstant, Self.seconds(now - last) < Self.minInterval { return }
        lastAnalysisInstant = now

        let frame = extractor.analyze(pixelBuffer, mirrored: mirrored, seq: seq, ts: ts)
        Task { await self.consume(frame) }
    }

    // MARK: - Detection (actor-isolated)

    private func consume(_ frame: LandmarkFrame) async {
        await processFrame(frame, policyTime: monotonicSeconds())
    }

    /// Test-support entry point: runs the detect -> policy -> sink path with
    /// an injected time, skipping the camera and Vision entirely.
    public func ingestForTesting(_ frame: LandmarkFrame, at time: TimeInterval) async {
        await processFrame(frame, policyTime: time)
    }

    /// Shared by the real camera path and `ingestForTesting`, so both take
    /// the identical detect -> policy -> sink path — the only thing that
    /// differs between them is where `policyTime` comes from.
    private func processFrame(_ frame: LandmarkFrame, policyTime: TimeInterval) async {
        publishFrame(frame)

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

    /// `static` (not actor-isolated) and pure so `didOutput` — `nonisolated`,
    /// confined to `frameQueue`, never on the actor — can share it with
    /// `monotonicSeconds()` above.
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

// MARK: - Production sink

/// The subset of `VCHost` that `HostSink` actually calls. Exists purely as a
/// unit-testing seam: `VCHost` dials a real gRPC socket in `connect()` and
/// cannot be constructed in a test, so tests inject a spy conforming to this
/// instead. `VCHost` itself needs no changes to conform — its `alert(_:)`
/// and `publish(topic:payload:)` already match this signature exactly.
public protocol AlertHost: Sendable {
    func alert(_ a: VCAlert) async throws
    func publish(topic: String, payload: Data) async throws
}

extension VCHost: AlertHost {}

/// One confirmed detection, broadcast to every `/api/events` SSE subscriber
/// via `HostSink.events()`. Deliberately a thin wrapper around `BFRBEvent`
/// rather than reusing it directly: `count` and `behavior` are
/// `fired(_:count:behavior:)` arguments, not part of `BFRBEvent` itself, and
/// a subscriber needs all three to render "3rd nail-biting nudge today".
public struct DetectionBroadcast: Sendable {
    public let event: BFRBEvent
    public let count: Int
    public let behavior: BFRBBehavior

    public init(event: BFRBEvent, count: Int, behavior: BFRBBehavior) {
        self.event = event
        self.count = count
        self.behavior = behavior
    }
}

/// Production `DetectionSink`: fans every confirmed detection out to
/// `/api/events` SSE subscribers, then — unless `SnoozeGate` says the alert
/// should be suppressed — alerts every connected client and publishes to the
/// bus. The publish is an enhancement gated on presence — nothing in this
/// tree subscribes to `vibecheck.behavior_detected.v1` today, so it simply
/// goes nowhere; it is not load-bearing for the alert.
///
/// An actor, not a struct, because `attach(host:)` and the SSE continuation
/// registry both need actor-isolated mutable state. `host` is optional and
/// settable after construction rather than a required `init` parameter:
/// `main.swift`'s composition root must register HTTP routes — and with them
/// `DetectionEngine`, which needs a `DetectionSink` at construction — before
/// `VCHost.connect()` can be called at all (see that file's ordering
/// comment), so no live `VCHost` exists yet at the point this sink is built.
/// `DetectionEngine.start()` runs only after `attach(host:)`, so `host` is
/// never actually nil when a real detection fires in production; a nil host
/// here only logs and still broadcasts to SSE, rather than crashing, for the
/// same "nothing in this plugin terminates the process" discipline as
/// everything else in it.
public actor HostSink: DetectionSink {
    private var host: (any AlertHost)?
    /// The consumer `AlertPrefsStore` was always waiting for (ruling
    /// T16c): `fired` reads `preferences(for:)` and prefers the stored
    /// `title`/`message` over `behavior.label`/`behavior.nudge` when they
    /// are non-empty. Before this, nothing in the package ever called
    /// `preferences(for:)` in production — the "Advanced: Alert Appearance"
    /// editor persisted to `alert-prefs.json` and did nothing.
    private let prefs: AlertPrefsStore
    private let snooze: SnoozeGate
    private var continuations: [UUID: AsyncStream<DetectionBroadcast>.Continuation] = [:]

    public init(prefs: AlertPrefsStore, snooze: SnoozeGate) {
        self.prefs = prefs
        self.snooze = snooze
    }

    /// Called once, from `main.swift`, right after `VCHost.connect()`
    /// returns.
    public func attach(host: any AlertHost) {
        self.host = host
    }

    /// A fan-out subscription for `/api/events`, same continuation-map shape
    /// as `DetectionEngine.frames()`/`VCHost.events()`.
    public func events() -> AsyncStream<DetectionBroadcast> {
        let (stream, continuation) = AsyncStream<DetectionBroadcast>.makeStream(
            of: DetectionBroadcast.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let key = UUID()
        continuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.dropContinuation(key) }
        }
        return stream
    }

    private func dropContinuation(_ key: UUID) {
        continuations.removeValue(forKey: key)
    }

    /// `nil` for both a never-set preference (`nil`) and an explicitly
    /// blanked one (`""`) — either way, the caller should fall back to the
    /// built-in copy rather than send core a blank title or body.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    public func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        // Broadcast first and unconditionally: a snooze suppresses the popup
        // alert, not the fact that a detection happened, and an SSE
        // subscriber (a future TUI client, say) wants the latter regardless.
        let broadcast = DetectionBroadcast(event: event, count: count, behavior: behavior)
        for continuation in continuations.values {
            continuation.yield(broadcast)
        }

        guard !(await snooze.isActive()) else { return }
        guard let host else {
            engineLog("detection fired before a host was attached; alert dropped (SSE still got it)")
            return
        }

        // Stored preferences win when the user actually set them; an empty
        // string (never explicitly cleared vs. never touched are
        // indistinguishable through this API today) falls back to the
        // built-in copy exactly like a `nil` does, rather than showing a
        // blank title or body.
        let preference = await prefs.preferences(for: behavior)
        let title = Self.nonEmpty(preference.title) ?? behavior.label
        let message = Self.nonEmpty(preference.message) ?? behavior.nudge

        // The `Ordinal.format(count)` suffix is appended REGARDLESS of
        // whether `message` came from the user or the built-in default —
        // deliberately, not merely preserving old behavior for the
        // fallback case. The count is what makes an alert feel responsive
        // to what's actually happening ("3rd nudge today") rather than a
        // static, repeated banner; a user who wrote their own encouraging
        // message presumably still wants to know it's counting, not lose
        // that context because they customized the wording around it.
        //
        // "warn" (not "info") so the banner holds 8s instead of 3s — only
        // "info" and "warn" exist; anything else silently renders as info.
        let alert = VCAlert(
            title: title,
            body: "\(message) — \(Ordinal.format(count)) nudge today",
            level: "warn",
            actions: [
                VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10"),
                VCAlertAction(label: "Turn off", url: "api/config/disable"),
            ]
        )
        // Neither failure is fatal: core may be mid-reconnect. Log and
        // continue — a dropped alert is not a reason to crash the detector.
        do {
            try await host.alert(alert)
        } catch {
            engineLog("alert failed: \(error)")
        }
        do {
            try await host.publish(topic: "vibecheck.behavior_detected.v1",
                                    payload: Data(behavior.rawValue.utf8))
        } catch {
            engineLog("publish failed: \(error)")
        }
    }
}
