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

    private var detector = BFRBDetector(sensitivity: 0.5)
    private var policy = DetectionPolicy(dwell: 0.4, cooldown: 5)
    private let interrupt: InterruptPlaying
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
    private let minInterval = 1.0 / 12.0

    init(interrupt: InterruptPlaying = InterruptPlayer()) {
        self.interrupt = interrupt
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

    @MainActor
    private func fire(_ event: BFRBEvent) {
        sessionCounts[event.behavior, default: 0] += 1
        interrupt.play(event.behavior)
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
