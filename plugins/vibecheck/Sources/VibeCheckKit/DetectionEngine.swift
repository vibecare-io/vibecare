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
    /// type uses it — `start()`/`stop()`/`apply()` call it sequentially,
    /// never concurrently, and `didOutput` below (nonisolated, confined to
    /// `frameQueue`) never touches `camera` itself, only receives callbacks
    /// from it. Same reasoning, same annotation, as
    /// `VibeCheckViewModel.camera` in the client this replaces.
    public nonisolated(unsafe) let camera = CameraSession()

    /// See the type-level doc comment: touched only on `CameraSession`'s
    /// private serial `frameQueue`, via `didOutput`, never concurrently with
    /// itself and never from the actor.
    nonisolated(unsafe) private let extractor = VisionLandmarkExtractor()
    /// Throttle timestamp. Same confinement as `extractor`.
    nonisolated(unsafe) private var lastAnalysisUnsafe = Date.distantPast
    /// Monotonic per-frame counter, incremented for every RAW camera frame —
    /// including ones the throttle below discards — so gaps in the sequence
    /// a downstream consumer sees are evidence of exactly which frames were
    /// dropped. Same confinement as `extractor`.
    nonisolated(unsafe) private var seqUnsafe: UInt64 = 0

    private let config: ConfigStore
    private let counts: CountsStore
    /// Not read by this type today — held because it is part of the plugin's
    /// alert-related dependency set (Task 15's `/api/alert-prefs` surface
    /// reads/writes the same store) and future per-behavior alert gating
    /// naturally lands here. Mirrors `HostSink.prefs` below for the same reason.
    private let prefs: AlertPrefsStore
    private var sink: DetectionSink

    private var detector = BFRBDetector(sensitivity: VibeCheckConfig.default.sensitivity)
    private var policy = DetectionPolicy(dwell: VibeCheckConfig.default.dwell,
                                          cooldown: VibeCheckConfig.default.cooldown)
    /// Live-applied settings. Re-read by `processFrame` on EVERY frame (not
    /// captured once) so a slider move via `apply(_:)` takes effect on the
    /// very next frame, exactly like `VibeCheckViewModel.consume` re-read its
    /// own `@Published` `sensitivity`/`alertInterval` every call.
    private var cachedConfig: VibeCheckConfig = .default

    private var running = false
    private var permission = "unknown"   // "granted" | "denied" | "noDevice" | "unknown"

    /// Mirrors on-disk counts so `snapshot()` can stay synchronous (no
    /// `await` needed to read `CountsStore`, which is itself an actor).
    /// Seeded from disk in `start()`, kept current by `fire(_:)` on every
    /// confirmed detection. NOT re-seeded on a bare day rollover with zero
    /// detections since the last `start()` — see the task report.
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

    public init(config: ConfigStore, counts: CountsStore, prefs: AlertPrefsStore, sink: DetectionSink) {
        self.config = config
        self.counts = counts
        self.prefs = prefs
        self.sink = sink
    }

    // MARK: - Lifecycle

    /// Full boot: loads the persisted config and today's counts, sets this
    /// engine as the camera's receiver, and starts the camera unconditionally
    /// — this method does not itself consult `config.enabled`. Whether to
    /// call it at all based on `enabled` is the caller's decision (`main.swift`
    /// at startup; `apply(_:)` below for a live enable/disable toggle). This
    /// mirrors `VibeCheckViewModel.start()`, which likewise starts
    /// unconditionally and leaves "should we start" to `setDetection`/
    /// `resumeIfEnabled`.
    @discardableResult
    public func start() async -> CameraStartResult {
        cachedConfig = await config.load()
        await loadTodayCounts()
        return await startCameraOnly()
    }

    public func stop() async {
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
    public func apply(_ newConfig: VibeCheckConfig) async {
        let wasEnabled = cachedConfig.enabled
        cachedConfig = newConfig
        guard wasEnabled != newConfig.enabled else { return }
        if newConfig.enabled {
            await startCameraOnly()
        } else {
            await stop()
        }
    }

    @discardableResult
    private func startCameraOnly() async -> CameraStartResult {
        camera.receiver = self
        let result = await camera.start()
        running = (result == .started)
        permission = Self.permissionString(for: result)
        return result
    }

    private static func permissionString(for result: CameraStartResult) -> String {
        switch result {
        case .started: return "granted"
        case .denied: return "denied"
        case .noDevice: return "noDevice"
        }
    }

    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(running: running, permission: permission, config: cachedConfig, todayCounts: todayCounts)
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
    /// that doesn't fold inference latency into the timestamp.
    public nonisolated func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool) {
        let ts = Date()
        seqUnsafe &+= 1
        let seq = seqUnsafe

        guard ts.timeIntervalSince(lastAnalysisUnsafe) >= Self.minInterval else { return }
        lastAnalysisUnsafe = ts

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
        let elapsed = ContinuousClock.now - clockEpoch
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: - Confirmed detections

    private func fire(_ event: BFRBEvent) async {
        let day = CountsStore.dayKey(Date())
        if cachedDay != day {
            // Crossed midnight (or this is the very first fire): the local
            // mirror is for a stale day and must not be blended with today's.
            todayCounts = [:]
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

/// Production `DetectionSink`: an alert to every connected client, plus a bus
/// publish. The publish is an enhancement gated on presence — nothing in this
/// tree subscribes to `vibecheck.behavior_detected.v1` today, so it simply
/// goes nowhere; it is not load-bearing for the alert.
public struct HostSink: DetectionSink {
    let host: VCHost
    /// Not read today — see `DetectionEngine.prefs`'s doc comment for why it
    /// is still carried here.
    let prefs: AlertPrefsStore

    public init(host: VCHost, prefs: AlertPrefsStore) {
        self.host = host
        self.prefs = prefs
    }

    public func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        // "warn" (not "info") so the banner holds 8s instead of 3s — only
        // "info" and "warn" exist; anything else silently renders as info.
        let alert = VCAlert(
            title: behavior.label,
            body: "\(behavior.nudge) — \(Ordinal.format(count)) nudge today",
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
