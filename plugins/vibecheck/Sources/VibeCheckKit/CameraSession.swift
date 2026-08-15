import AVFoundation
import Foundation

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — same rule as
/// `VCPluginSDK/VCLog.swift`: the `FileHandle` overload raises an
/// *uncatchable* `NSException` on a closed descriptor, and core closes the
/// plugin's stderr pipe during its own shutdown. `supervisor.go` charges the
/// resulting abort as a failed start. `VCPluginSDK`'s own `vcLog` is
/// internal to that module, so `VibeCheckKit` needs its own copy.
private func cameraLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

public protocol CameraFrameReceiver: AnyObject, Sendable {
    /// `mirrored` reports whether the SOURCE connection already mirrored x.
    /// The extractor uses it to normalize into viewer space; nothing
    /// downstream of `LandmarkFrame` ever sees it.
    func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool)
}

public enum CameraStartResult: Sendable, Equatable {
    case started
    case denied
    case noDevice
}

/// `AVCaptureSession` isn't `Sendable`, but `CameraSession` only ever mutates it
/// synchronously during `configure()` (before `start()` dispatches to `frameQueue`)
/// and thereafter touches it exclusively from closures run on `frameQueue`, which
/// serializes all access. This assertion documents that manual synchronization.
extension AVCaptureSession: @retroactive @unchecked Sendable {}

/// Wraps an AVCaptureSession that streams downscaled webcam frames on a
/// dedicated background queue. Frame analysis (Vision) runs off the delegate
/// callback so the plugin's HTTP/gRPC handling is never blocked.
///
/// Unlike the client's original, this has no `previewLayer`: that is
/// `AVCaptureVideoPreviewLayer`, CoreAnimation handed to the window server,
/// which is meaningless in a headless daemon. Its replacement is the MJPEG
/// stream added in a later task. Deleting it does not break mirroring —
/// `automaticallyAdjustsVideoMirroring` belongs to `AVCaptureConnection`, and
/// the data output's connection has its own instance independent of any
/// preview layer's connection.
public final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public weak var receiver: CameraFrameReceiver?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frameQueue: DispatchQueue

    public init(frameQueueLabel: String = "com.vibecare.vibecheck.camera") {
        self.frameQueue = DispatchQueue(label: frameQueueLabel, qos: .userInitiated)
        super.init()
    }

    /// Requests permission, configures the session, and starts it.
    ///
    /// Returns why it failed, because the UI must tell "grant camera access"
    /// apart from "no camera found" — and because neither is a reason to
    /// exit the process. Core charges any unrequested process exit as a
    /// failed start; five in a row park the plugin in `StateFailed` until a
    /// manual dashboard restart, so a missing/denied camera must degrade,
    /// never terminate.
    ///
    /// Idempotent: safe to call again after the owning caller persists
    /// across navigation. `configure()` only runs once — calling it twice
    /// would re-add inputs/outputs to `session` and throw a runtime error —
    /// and `startRunning()` only runs if the session isn't already running.
    public func start() async -> CameraStartResult {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // Needs a live run loop to deliver the completion. main.swift
            // parks on `host.waitForShutdown()` rather than returning, so
            // one exists.
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        if session.inputs.isEmpty {
            guard configure() else { return .noDevice }
        }
        frameQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return .started
    }

    public func stop() {
        frameQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Whether the currently configured output connection is source-mirrored,
    /// exposed for diagnostics (e.g. the `--probe-camera` startup check).
    /// The per-frame value handed to the receiver in `captureOutput` is the
    /// one that actually matters — see the comment there.
    public var isSourceMirrored: Bool {
        output.connection(with: .video)?.isVideoMirrored ?? true
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            cameraLog("No camera device / input available")
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
        // auto-mirrors the built-in front camera on the data output by
        // default (automaticallyAdjustsVideoMirroring), and that default is
        // applied consistently at all times. Manually forcing it in
        // configure() only takes effect when the connection happens to be
        // ready, which flips the published coordinate space on exactly one
        // of first-open / re-open — this was hit and fixed empirically in
        // the client this was ported from. Leaving auto-mirroring on and
        // reading `connection.isVideoMirrored` per frame (see
        // captureOutput below) keeps it correct across restarts regardless
        // of timing, and also correctly reports `false` for an external
        // webcam or Continuity Camera, which macOS does not auto-mirror.
        return true
    }

    public func captureOutput(_ output: AVCaptureOutput,
                               didOutput sampleBuffer: CMSampleBuffer,
                               from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Read it per frame rather than caching: isVideoMirrored is only
        // meaningful once the connection is ready, and forcing/caching it
        // at configure() time took effect on first-open but not re-open,
        // flipping the coordinate space depending on timing.
        receiver?.didOutput(pixelBuffer, mirrored: connection.isVideoMirrored)
    }
}
