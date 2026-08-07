import SwiftUI
import AVFoundation

@MainActor
final class VibeCheckViewModel: ObservableObject, CameraFrameReceiver {
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var latestFrame = LandmarkFrame(hand: nil, face: nil)

    @Published var enabledBehaviors: Set<BFRBBehavior> = Set(BFRBBehavior.allCases)
    @Published var sensitivity: Double = 0.5
    @Published var alertInterval: Double = 5       // cooldown seconds
    @Published var sessionCounts: [BFRBBehavior: Int] = [:]
    @Published var flash = false
    @Published var showOverlay = true

    /// App-wide instance shared by the Dashboard toolbar and the menu-bar
    /// scene so a single camera session backs both toggles. Tests must NOT
    /// use this — they construct their own VM via `init(...)`.
    static let shared = VibeCheckViewModel()

    /// Reflects the user's explicit intent to run detection. Distinct from
    /// `isRunning` (actual camera state): they can diverge briefly, e.g. when
    /// permission is denied on resume the intent resolves back to `false`.
    @Published private(set) var isDetectionEnabled: Bool

    private var preference: DetectionPreferenceStoring

    /// Reentrancy guard for `setDetection`. Toolbar and menu-bar toggles are
    /// both always visible and can fire near-simultaneously; `setDetection`
    /// suspends inside `await start()` before `isDetectionEnabled` reflects
    /// the new intent, so a second call arriving during that suspension would
    /// otherwise also read the stale value and call `camera.start()` again —
    /// violating `camera`'s documented sequential-only start/stop invariant.
    /// Only ever touched on the main actor, so a plain `Bool` suffices.
    private var isTransitioning = false

    private var detector = BFRBDetector(sensitivity: 0.5)
    private var policy = DetectionPolicy(dwell: 0.15, cooldown: 5)
    private let interrupt: InterruptPlaying
    private let notifier: DetectionNotifying
    private let pluginService = PluginService()
    private static let vibeCheckPluginId = "com.vibecare.vibecheck"

    /// `CameraSession` isn't `Sendable`. `nonisolated(unsafe)` asserts only that
    /// *this* reference is safe to await across the actor boundary the way this
    /// view model uses it (calling `start()`/`stop()` sequentially, never
    /// concurrently) — it does not make a type-wide Sendable claim about
    /// `CameraSession`, so Swift's data-race checking still applies to any other
    /// use of the type (e.g. `camera.receiver` set on the main actor and read on
    /// `frameQueue` in later tasks).
    nonisolated(unsafe) let camera = CameraSession()

    /// `VisionLandmarkExtractor` isn't `Sendable` (it wraps Vision request
    /// objects), so it doesn't qualify for the "immutable + Sendable" exception
    /// that would let a `let` on a `@MainActor` type be read from a nonisolated
    /// context for free. `didOutput(_:)` below runs on `CameraSession`'s private
    /// serial `frameQueue`, never concurrently with itself, so reusing one
    /// instance there is safe — `nonisolated(unsafe)` documents that confinement
    /// the same way `camera` above does. It is never touched from the main actor.
    nonisolated(unsafe) private let extractor = VisionLandmarkExtractor()

    /// Throttle timestamp for `didOutput`. Touched only on `frameQueue`, which
    /// serializes all camera frame callbacks, so plain `nonisolated(unsafe)` is
    /// sufficient — there is no concurrent access to guard against.
    nonisolated(unsafe) private var lastAnalysisUnsafe = Date.distantPast
    private let minInterval = 1.0 / 15.0

    init(
        interrupt: InterruptPlaying = InterruptPlayer(),
        notifier: DetectionNotifying = VibeNotifyDetectionNotifier(),
        preference: DetectionPreferenceStoring = DetectionPreference()
    ) {
        self.interrupt = interrupt
        self.notifier = notifier
        self.preference = preference
        self.isDetectionEnabled = preference.enabled
    }

    func start() async {
        camera.receiver = self
        let ok = await camera.start()
        isRunning = ok
        permissionDenied = !ok
    }

    func stop() {
        camera.stop()
        isRunning = false
    }

    /// Turns detection on or off and persists the resolved intent. When
    /// turning on, `isDetectionEnabled` follows whether the camera actually
    /// started (`isRunning`) — a denied permission resolves the flag back to
    /// `false` so resume can't loop into a broken state.
    func setDetection(_ on: Bool) async {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        if on {
            await start()
            isDetectionEnabled = isRunning
        } else {
            stop()
            isDetectionEnabled = false
        }
        preference.enabled = isDetectionEnabled
    }

    func toggleDetection() async {
        await setDetection(!isDetectionEnabled)
    }

    /// Called once at app startup: restores detection if it was on at last quit.
    /// No-op when the camera is already running so reopening the main window
    /// (which recreates `ContentView` and re-fires its startup `.onAppear`)
    /// doesn't redundantly restart an already-running camera.
    func resumeIfEnabled() async {
        guard !isRunning else { return }
        if preference.enabled {
            await setDetection(true)
        }
    }

    nonisolated func didOutput(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        // Throttle on the camera queue; hop to main only to publish.
        guard now.timeIntervalSince(lastAnalysisUnsafe) >= minInterval else { return }
        lastAnalysisUnsafe = now
        let frame = extractor.analyze(pixelBuffer)
        Task { @MainActor in self.consume(frame) }
    }

    /// Publishes the latest frame and runs detection on the main actor.
    /// `detector`/`policy` are cheap pure value types owned by this
    /// `@MainActor` view model, so running them here (rather than on
    /// `frameQueue`) keeps all mutable detection state single-threaded
    /// without needing extra synchronization.
    @MainActor
    private func consume(_ frame: LandmarkFrame) {
        latestFrame = frame
        detector.sensitivity = sensitivity
        policy.cooldown = alertInterval
        let result = detector.detect(frame, enabled: enabledBehaviors)
        if let event = policy.ingest(result, at: Date().timeIntervalSinceReferenceDate) {
            fire(event)
        }
    }

    /// Handles a confirmed detection. `internal` (not `private`) so tests can
    /// drive it directly with a `BFRBEvent`, exercising the notify + count
    /// wiring without a camera/CVPixelBuffer.
    @MainActor
    func fire(_ event: BFRBEvent) {
        sessionCounts[event.behavior, default: 0] += 1
        interrupt.play(event.behavior)
        notifier.notify(behavior: event.behavior, count: sessionCounts[event.behavior, default: 0])
        report(event)
        flash = true
        Task { try? await Task.sleep(for: .milliseconds(250)); flash = false }
    }

    /// Reports a confirmed detection to `plugin-vibecheck` so it persists for
    /// the stats view. Fire-and-forget: `PluginService.invoke` throws on
    /// failure (unlike `listPlugins`), so we swallow the error with `try?` —
    /// a failed report must never disrupt the local interrupt, which has
    /// already fired synchronously above.
    @MainActor
    private func report(_ event: BFRBEvent) {
        let params = [
            "behavior": event.behavior.rawValue,
            "ts": ISO8601DateFormatter().string(from: Date())
        ]
        Task {
            _ = try? await pluginService.invoke(
                pluginId: Self.vibeCheckPluginId,
                viewId: "main",
                action: "record_detection",
                params: params
            )
        }
    }
}

// MARK: - Detection notifier

/// Surfaces a confirmed detection to the user. Abstracted (like `interrupt`)
/// so `VibeCheckViewModel` can be tested with a spy instead of popping a real
/// window. Only the method is `@MainActor` (not the whole protocol) so the
/// production conformer's type stays nonisolated and can be used as a default
/// initializer argument.
protocol DetectionNotifying {
    @MainActor func notify(behavior: BFRBBehavior, count: Int)
}

/// Production notifier: a VibeNotify center card with the behavior's icon and
/// nudge (see `VibeNotifyConfig.showBFRBAlert`).
struct VibeNotifyDetectionNotifier: DetectionNotifying {
    @MainActor func notify(behavior: BFRBBehavior, count: Int) {
        VibeNotifyConfig.showBFRBAlert(behavior: behavior, count: count)
    }
}
