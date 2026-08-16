import AVFoundation
import Foundation

/// A camera the user could pick, as reported to `/api/state`.
public struct VisionCamera: Sendable, Codable, Equatable, Identifiable {
    /// `AVCaptureDevice.uniqueID` — stable across launches, and what
    /// `Header.device_id` carries so a consumer can tell which camera a frame
    /// came from.
    public let id: String
    public let name: String
    /// Whether this is what `AVCaptureDevice.default(for: .video)` returns,
    /// i.e. what the provider opens when the user has never chosen.
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public protocol CameraFrameReceiver: AnyObject, Sendable {
    /// `mirrored` reports whether the SOURCE connection already mirrored x,
    /// read from `AVCaptureConnection.isVideoMirrored` on **this** frame. It
    /// is the single source of truth every downstream flip derives from —
    /// landmarks, mask columns and the preview JPEG alike.
    func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool, deviceID: String)
}

public enum CameraStartResult: String, Sendable, Equatable, Codable {
    case started
    case denied
    case noDevice
}

/// Everything `VisionProvider` does to a camera.
///
/// A seam, and not an optional one: `swift test` runs in a process with no
/// `NSCameraUsageDescription` and no TCC grant, so a test that reached a real
/// `AVCaptureDevice.requestAccess` would either hang on a prompt or fail in a
/// way that says nothing about the code under test. The demand floor — "every
/// vision topic at zero subscribers STOPS the session" — is one of the most
/// important behaviours in this plugin, and it is only assertable because the
/// thing being stopped can be a fake.
public protocol VisionCameraControlling: Sendable {
    /// The serial queue frame callbacks arrive on. Also where the frame path's
    /// `VNRequest`s are constructed and released, so that all of it stays
    /// single-threaded.
    var frameQueue: DispatchQueue { get }
    /// The camera currently open, or `nil` when the session is closed.
    var currentCamera: VisionCamera? { get }
    /// Set once, at wiring time, before any frame can arrive.
    func attach(_ receiver: any CameraFrameReceiver)
    func availableCameras() -> [VisionCamera]
    func setPreferredDevice(id: String?)
    func start() async -> CameraStartResult
    func stop()
    /// Drops the input so the next `start()` reconfigures from scratch.
    func reset() async
    func setFrameRate(_ fps: Int)
}

/// `AVCaptureSession` isn't `Sendable`, but `CameraSession` only ever mutates
/// it from closures run on `frameQueue`, which serializes all access. This
/// assertion documents that manual synchronization.
extension AVCaptureSession: @retroactive @unchecked Sendable {}

/// Wraps an `AVCaptureSession` that streams webcam frames on a dedicated
/// background queue. Inference runs off the delegate callback so the plugin's
/// HTTP and gRPC handling is never blocked.
///
/// There is no `previewLayer`: that is `AVCaptureVideoPreviewLayer`,
/// CoreAnimation handed to the window server, which is meaningless in a
/// headless daemon. Its replacement is `PreviewStream`'s MJPEG. Deleting it
/// does not break mirroring — `automaticallyAdjustsVideoMirroring` belongs to
/// `AVCaptureConnection`, and the data output's connection has its own
/// instance independent of any preview layer's.
///
/// `@unchecked Sendable` under one argument: every piece of mutable state is
/// either confined to `frameQueue` (the session, the output, `currentDevice`)
/// or guarded by `deviceLock` (the id/name snapshot and the preferred device).
/// `receiver` is written once at wiring time, before any frame can arrive.
public final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                  VisionCameraControlling, @unchecked Sendable {
    public weak var receiver: (any CameraFrameReceiver)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()

    /// The serial queue every frame callback and every session mutation runs
    /// on. Exposed because the frame-path objects confined to it (the Vision
    /// requests) have to be released from it too, even when no frames are
    /// arriving — see `FrameProcessor.applyPlan`.
    public let frameQueue: DispatchQueue

    /// The device currently attached, or `nil` before the first `configure`.
    /// Read from the frame callback (to stamp `Header.device_id`) and written
    /// only on `frameQueue`, so it is protected by that queue's serialization.
    private var currentDevice: AVCaptureDevice?

    /// A lock-free snapshot of `currentDevice.uniqueID` for callers that are
    /// not on `frameQueue` (the actor building `/api/state`). `nonisolated(unsafe)`
    /// with an `NSLock` rather than an actor, because the frame path must not
    /// suspend.
    private let deviceLock = NSLock()
    private var deviceIDLocked: String = ""
    private var deviceNameLocked: String = ""

    public init(frameQueueLabel: String = "com.vibecare.vision.camera") {
        self.frameQueue = DispatchQueue(label: frameQueueLabel, qos: .userInitiated)
        super.init()
    }

    // MARK: - Devices

    /// Every camera the machine currently has. Safe to call before any
    /// permission has been granted — discovery reports device names without a
    /// TCC prompt; only opening one prompts.
    public static func availableCameras() -> [VisionCamera] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        return discovery.devices.map {
            VisionCamera(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }
    }

    /// The device currently attached, or `nil` if the session was never
    /// configured.
    public var currentCamera: VisionCamera? {
        deviceLock.withLock {
            guard !deviceIDLocked.isEmpty else { return nil }
            return VisionCamera(id: deviceIDLocked, name: deviceNameLocked, isDefault: false)
        }
    }

    /// The id stamped into `Header.device_id`.
    public var currentDeviceID: String {
        deviceLock.withLock { deviceIDLocked }
    }

    /// Instance form of `availableCameras()`, so the protocol can be
    /// satisfied by a fake that has no `AVCaptureDevice` at all.
    public func availableCameras() -> [VisionCamera] { Self.availableCameras() }

    public func attach(_ receiver: any CameraFrameReceiver) { self.receiver = receiver }

    /// The device the next `start()` will open. `nil` means "whatever
    /// `AVCaptureDevice.default` says". Written from the actor, read on
    /// `frameQueue` during `configure`, so it takes the same lock.
    private var preferredDeviceID: String?

    /// Chooses the camera to use. Takes effect on the next configure — the
    /// caller stops and restarts capture to switch a live session, which also
    /// makes the switch visible as a `device_id` change in `Header`.
    public func setPreferredDevice(id: String?) {
        deviceLock.withLock { preferredDeviceID = id }
    }

    // MARK: - Lifecycle

    /// Requests permission, configures the session, and starts it.
    ///
    /// Returns **why** it failed rather than throwing, because the readout has
    /// to tell "grant camera access" apart from "no camera found" — and
    /// because neither is a reason to exit. Core charges any unrequested
    /// process exit as a failed start and five park the plugin in
    /// `StateFailed`, so a missing or denied camera degrades and is retried
    /// forever, never terminates.
    ///
    /// Idempotent: `configure()` only runs once (calling it twice would re-add
    /// inputs and outputs and throw), and `startRunning()` only runs if the
    /// session is not already running.
    public func start() async -> CameraStartResult {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // Needs a live run loop to deliver the completion. `main.swift`
            // parks on `host.waitForShutdown()` rather than returning, so one
            // exists.
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        if session.inputs.isEmpty {
            guard await configureOnQueue() else { return .noDevice }
        }
        frameQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return .started
    }

    /// Stops the session — the LED goes off. Idempotent.
    public func stop() {
        frameQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Tears the input down so the *next* `start()` reconfigures from scratch.
    /// Used by camera switching, which cannot mutate a live session's input
    /// without a full begin/commit cycle anyway.
    public func reset() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            frameQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
        deviceLock.withLock {
            deviceIDLocked = ""
            deviceNameLocked = ""
        }
    }

    /// Asks the device to deliver at most `fps` frames a second.
    ///
    /// This is the battery half of the rate story; `RateGate` is the
    /// correctness half. The gates alone already produce the right publish
    /// rates by discarding frames, but discarding a frame the sensor and ISP
    /// already produced saves nothing — so the session is told the ceiling
    /// too. A device that refuses the request is logged and ignored, because
    /// the gates still make the output correct.
    public func setFrameRate(_ fps: Int) {
        guard fps > 0 else { return }
        frameQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            let wanted = CMTime(value: 1, timescale: CMTimeScale(fps))
            // Never ask for something outside the active format's range: a
            // value the format cannot honour throws, and an unhandled throw
            // here would be a crash on a code path a user reaches by moving a
            // slider.
            guard let range = device.activeFormat.videoSupportedFrameRateRanges.first else { return }
            let clamped = max(range.minFrameDuration, min(range.maxFrameDuration, wanted))
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = clamped
                device.unlockForConfiguration()
            } catch {
                visionLog("could not set capture frame rate to \(fps): \(error)")
            }
        }
    }

    // MARK: - Configuration

    private func configureOnQueue() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            frameQueue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                continuation.resume(returning: self.configure())
            }
        }
    }

    /// Must run on `frameQueue`.
    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720

        let preferred = deviceLock.withLock { preferredDeviceID }

        let device: AVCaptureDevice?
        if let preferred, let match = AVCaptureDevice(uniqueID: preferred) {
            device = match
        } else {
            if preferred != nil {
                visionLog("preferred camera \(preferred!) is gone; falling back to the default device")
            }
            device = AVCaptureDevice.default(for: .video)
        }

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            visionLog("no camera device / input available")
            return false
        }
        session.addInput(input)
        currentDevice = device
        deviceLock.withLock {
            deviceIDLocked = device.uniqueID
            deviceNameLocked = device.localizedName
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
        }

        // Deliberately DON'T touch mirroring on the output connection.
        //
        // It was measured that with `automaticallyAdjustsVideoMirroring` left
        // at its default, both this data output's connection and a
        // temporarily-added preview layer's connection report
        // `isVideoMirrored == false` for the built-in camera — whose
        // `AVCaptureDevice.position` is `.unspecified`, not `.front`, so
        // whatever heuristic macOS uses to auto-mirror never fires. macOS is
        // not silently doing the right thing here, so this plugin mirrors both
        // surfaces itself, driven by the per-frame value the connection
        // actually reports.
        //
        // Forcing or caching a value here would also reintroduce the original
        // first-open-vs-reopen timing bug: `isVideoMirrored` is only
        // meaningful once the connection is ready. Read it per frame instead
        // and forward it as-is.
        return true
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let deviceID = deviceLock.withLock { deviceIDLocked }
        // Per frame, never cached — see `configure()` and
        // `ViewerSpaceMapping`.
        receiver?.didOutput(pixelBuffer, mirrored: connection.isVideoMirrored, deviceID: deviceID)
    }
}
