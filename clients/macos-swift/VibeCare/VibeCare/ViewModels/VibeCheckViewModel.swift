import SwiftUI
import AVFoundation

@MainActor
final class VibeCheckViewModel: ObservableObject, CameraFrameReceiver {
    @Published var isRunning = false
    @Published var permissionDenied = false
    @Published var latestFrame = LandmarkFrame(hand: nil, face: nil)

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
        Task { @MainActor in self.latestFrame = frame }
    }
}
