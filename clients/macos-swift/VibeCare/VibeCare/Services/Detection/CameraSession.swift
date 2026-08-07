import AVFoundation
import Logging

protocol CameraFrameReceiver: AnyObject {
    func didOutput(_ pixelBuffer: CVPixelBuffer)
}

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
    func start() async -> Bool {
        let authorized = await ensureAuthorized()
        guard authorized else { return false }
        guard configure() else { return false }
        frameQueue.async { [session] in session.startRunning() }
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
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        receiver?.didOutput(pixelBuffer)
    }
}
