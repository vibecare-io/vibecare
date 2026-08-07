import SwiftUI
import AVFoundation

@MainActor
final class VibeCheckViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var permissionDenied = false

    /// `CameraSession` isn't `Sendable`. `nonisolated(unsafe)` asserts only that
    /// *this* reference is safe to await across the actor boundary the way this
    /// view model uses it (calling `start()`/`stop()` sequentially, never
    /// concurrently) — it does not make a type-wide Sendable claim about
    /// `CameraSession`, so Swift's data-race checking still applies to any other
    /// use of the type (e.g. `camera.receiver` set on the main actor and read on
    /// `frameQueue` in later tasks).
    nonisolated(unsafe) let camera = CameraSession()

    func start() async {
        let ok = await camera.start()
        isRunning = ok
        permissionDenied = !ok
    }

    func stop() {
        camera.stop()
        isRunning = false
    }
}
