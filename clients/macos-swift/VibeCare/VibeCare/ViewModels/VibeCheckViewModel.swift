import SwiftUI
import AVFoundation

/// `CameraSession` isn't `Sendable`, but its only mutable state (`receiver`) is a
/// `weak var` set once by callers and its `AVCaptureSession` access is already
/// manually synchronized (see `CameraSession`'s own doc comment). Declaring this
/// here — rather than in `CameraSession.swift` — keeps this task's changes scoped
/// to the VibeCheck files while letting `start()`/`stop()` be awaited from the
/// `@MainActor`-isolated view model without a "sending non-Sendable value" error.
extension CameraSession: @unchecked Sendable {}

@MainActor
final class VibeCheckViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var permissionDenied = false

    let camera = CameraSession()

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
