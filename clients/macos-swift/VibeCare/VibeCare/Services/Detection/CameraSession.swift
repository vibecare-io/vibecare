import AVFoundation
import Logging

protocol CameraFrameReceiver: AnyObject {
    func didOutput(_ pixelBuffer: CVPixelBuffer)
}

/// `AVCaptureSession` isn't `Sendable`, but `CameraSession` only ever mutates it
/// synchronously during `configure()` (before `start()` dispatches to `frameQueue`)
/// and thereafter touches it exclusively from closures run on `frameQueue`, which
/// serializes all access. This assertion documents that manual synchronization.
extension AVCaptureSession: @retroactive @unchecked Sendable {}

/// Wraps an AVCaptureSession that streams downscaled webcam frames on a
/// dedicated background queue. Frame analysis (Vision) runs off the delegate
/// callback so the main thread is never blocked.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let previewLayer: AVCaptureVideoPreviewLayer
    weak var receiver: CameraFrameReceiver?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue: DispatchQueue
    private let logger = Logger(label: "com.vibecare.camera")

    init(frameQueueLabel: String = "com.vibecare.camera") {
        self.frameQueue = DispatchQueue(label: frameQueueLabel, qos: .userInitiated)
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
    }

    /// Requests permission, configures the session, and starts it.
    /// Returns false if permission is denied or no camera is available.
    ///
    /// Idempotent: safe to call again after the owning view model persists
    /// across navigation (e.g. the user re-selects VibeCheck and the camera
    /// view re-appears). `configure()` only runs once — calling it twice
    /// would re-add inputs/outputs to `session` and throw a runtime error —
    /// and `startRunning()` only runs if the session isn't already running.
    func start() async -> Bool {
        let authorized = await ensureAuthorized()
        guard authorized else { return false }
        if session.inputs.isEmpty {
            guard configure() else { return false }
        }
        frameQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return true
    }

    func stop() {
        frameQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            logger.error("No camera device / input available")
            return false
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)

        // Deliberately DON'T touch mirroring on the output connection. macOS
        // auto-mirrors the built-in front camera on both the preview and the
        // data output by default (automaticallyAdjustsVideoMirroring), and that
        // default is applied consistently at all times. Manually forcing it —
        // in configure() or in the preview's make/updateNSView — only takes
        // effect when the connection happens to be ready, which flips the
        // overlay's coordinate space on exactly one of first-open / re-open.
        // Leaving auto-mirroring on keeps preview and Vision buffer in sync, so
        // the overlay's no-x-flip mapping stays correct across navigation.
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        receiver?.didOutput(pixelBuffer)
    }
}
