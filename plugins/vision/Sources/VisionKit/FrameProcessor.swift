import CoreVideo
import Foundation
import VCGeometry
import VCKStubs

/// A `CVPixelBuffer` wrapped so it can cross into an unstructured `Task`.
///
/// The compiler's region-based `sending` check cannot prove the frame path is
/// done with the buffer when the closure captures it, and it is right not to
/// try. `CVPixelBuffer` is a CF reference type and handing it to another
/// concurrency domain for a read-only encode is safe; the box is where that
/// claim is written down rather than scattered across call sites.
struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Source pixel dimensions of the frames currently arriving, and the mirror
/// flag the connection reported for the most recent one.
///
/// The dimensions are what an overlay's aspect-fill mapping is computed
/// against — every coordinate on the wire is normalized against them, and a UI
/// that assumed 16:9 would drift the overlay off the face on any other ratio.
/// `mirrored` is here for diagnostics only: everything published is ALREADY in
/// viewer space, so a consumer that mirrors again on the strength of this
/// field has double-flipped.
public struct VisionFrameGeometry: Sendable, Equatable, Codable {
    public var width: Int = 0
    public var height: Int = 0
    public var mirrored: Bool = false

    public init(width: Int = 0, height: Int = 0, mirrored: Bool = false) {
        self.width = width
        self.height = height
        self.mirrored = mirrored
    }
}

/// Counters the readout reports. Cheap, and the only way to tell "the camera
/// is open but nothing is being published" apart from "the camera is closed"
/// from outside the process.
public struct VisionCounters: Sendable, Equatable, Codable {
    /// Raw camera frames received.
    public var captured: UInt64 = 0
    /// Frames on which at least one model ran.
    public var analyzed: UInt64 = 0
    /// Bus messages handed to the SDK.
    public var published: UInt64 = 0
    /// Bus messages dropped rather than queued without bound — a wedged core,
    /// or a publish slower than the capture rate.
    public var dropped: UInt64 = 0

    public init() {}
}

/// The whole frame path, confined to `CameraSession.frameQueue`.
///
/// ## Why this is a class with a lock rather than an actor
///
/// `didOutput` is called synchronously by AVFoundation on one serial queue and
/// must not suspend: hopping onto an actor would let two frames' analyses
/// interleave, and `VisionAnalyzing`'s conformers hold `VNRequest`s whose
/// `.results` are overwritten per `perform` — interleaving them
/// cross-contaminates results between frames. So the analyzer, the rate gates
/// and the sequence counter are touched **only** from `frameQueue`, and the
/// handful of fields the actor also reads (the plan, the carried frames, the
/// counters) are guarded by one `NSLock` held for a few assignments at a time.
///
/// This is the same confinement argument the detector this replaces made with
/// `nonisolated(unsafe) let extractor`. Nothing here claims `VNRequest` is
/// thread-safe; it claims this specific usage is single-threaded.
public final class FrameProcessor: CameraFrameReceiver, @unchecked Sendable {
    private let analyzer: any VisionAnalyzing
    private let queue: DispatchQueue
    private let preview: PreviewStream?
    private let signalsComputer: VisionSignalsComputer?
    private let emit: @Sendable (VisionTopic, Data) -> Void

    // MARK: frameQueue-confined state
    private var seq: UInt64 = 0
    private var gate = RateGate()
    /// Most recent output per model, carried forward — see `carriedBundle`.
    private var carriedFace: VCTFaceFrame?
    /// Carried with `carriedFace` and cleared with it: a layout without the
    /// points it describes is meaningless, and points without their layout are
    /// worse than meaningless.
    private var carriedFaceLayout: FaceLandmarkLayout?
    private var carriedHands: VCTHandsFrame?
    private var carriedBody: VCTBodyPoseFrame?
    private var carriedSegmentation: VCTSegmentationFrame?

    // MARK: lock-guarded state
    private let lock = NSLock()
    private var planLocked: VisionPlan = .idle
    private var latestLocked: VisionFrameBundle?
    private var countersLocked = VisionCounters()
    private var geometryLocked = VisionFrameGeometry()
    private var frameSinksLocked: [UUID: AsyncStream<VisionFrameBundle>.Continuation] = [:]

    /// - Parameters:
    ///   - analyzer: the inference seam. Owned outright — nothing else may
    ///     touch it, because only this type's `frameQueue` confinement makes
    ///     its `Sendable` conformance honest.
    ///   - queue: `CameraSession.frameQueue` in production. A dedicated serial
    ///     queue in tests.
    ///   - emit: hands one serialized topic payload to the publish path.
    ///     Non-blocking by contract: it must enqueue, never await the RPC, or
    ///     it would stall the camera callback behind a wedged core.
    public init(analyzer: any VisionAnalyzing,
                queue: DispatchQueue,
                preview: PreviewStream? = nil,
                signalsComputer: VisionSignalsComputer? = nil,
                emit: @escaping @Sendable (VisionTopic, Data) -> Void) {
        self.analyzer = analyzer
        self.queue = queue
        self.preview = preview
        self.signalsComputer = signalsComputer
        self.emit = emit
    }

    // MARK: - Control plane -> frame path

    /// Installs a new plan.
    ///
    /// Two things happen, and both are necessary. The plan is stored for the
    /// next frame to read, **and** a model sync is dispatched onto the frame
    /// queue immediately. The dispatch is not redundant: when a plan drops to
    /// idle the camera stops, so no further frame ever arrives — and without
    /// this, the released models would sit holding resources until the next
    /// time somebody asked for a topic, which could be never.
    public func applyPlan(_ plan: VisionPlan) {
        lock.lock()
        planLocked = plan
        lock.unlock()
        queue.async { [weak self] in
            self?.syncModels(to: plan)
        }
    }

    public var plan: VisionPlan {
        lock.lock()
        defer { lock.unlock() }
        return planLocked
    }

    /// The most recent frame's landmarks, for the UI overlay and `/api/state`.
    public var latestFrames: VisionFrameBundle? {
        lock.lock()
        defer { lock.unlock() }
        return latestLocked
    }

    public var counters: VisionCounters {
        lock.lock()
        defer { lock.unlock() }
        return countersLocked
    }

    /// Source pixel dimensions and the last mirror flag. The overlay's
    /// aspect-fill mapping needs the dimensions, and a UI that assumed 16:9
    /// would drift the overlay off the face on any other ratio.
    public var geometry: VisionFrameGeometry {
        lock.lock()
        defer { lock.unlock() }
        return geometryLocked
    }

    /// A fan-out of every analysed frame, for a `/api/events` overlay stream.
    ///
    /// Idles for free: with no stream outstanding, `didOutput` never builds a
    /// value to yield. Buffering is `.bufferingNewest(2)` because an overlay
    /// wants the freshest frame and has no use whatsoever for a backlog — a
    /// browser that fell behind should skip, not replay.
    public func frames() -> AsyncStream<VisionFrameBundle> {
        let (stream, continuation) = AsyncStream<VisionFrameBundle>.makeStream(
            of: VisionFrameBundle.self,
            bufferingPolicy: .bufferingNewest(2)
        )
        let key = UUID()
        lock.withLock { frameSinksLocked[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.frameSinksLocked.removeValue(forKey: key) }
        }
        return stream
    }

    /// Finishes every outstanding frame stream, so a `/api/events` handler
    /// awaiting one returns instead of hanging through shutdown.
    public func finishFrameStreams() {
        let sinks = lock.withLock { () -> [AsyncStream<VisionFrameBundle>.Continuation] in
            let all = Array(frameSinksLocked.values)
            frameSinksLocked.removeAll()
            return all
        }
        for sink in sinks { sink.finish() }
    }

    /// The topics whose models currently exist. Reads the analyzer, so it must
    /// hop onto the frame queue — used by the readout, never by the frame
    /// path.
    public func activeModels() async -> Set<VisionTopic> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<VisionTopic>, Never>) in
            queue.async { [analyzer] in
                continuation.resume(returning: analyzer.activeModels)
            }
        }
    }

    // MARK: - Frame path (frameQueue only)

    public func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool, deviceID: String) {
        // Sampled at entry: the earliest point available, and the only one
        // that does not fold inference latency into the timestamp.
        let ts = Date()

        // Every raw frame, unconditionally, BEFORE any inference gate.
        // `PreviewStream.publish` has its own looser cadence and idles for
        // free when nobody is attached, so this costs nothing when nobody is
        // watching.
        if let preview {
            let box = PixelBufferBox(buffer: pixelBuffer)
            Task { await preview.publish(box.buffer, mirrored: mirrored) }
        }

        seq &+= 1
        let frameSeq = seq
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        lock.withLock {
            countersLocked.captured &+= 1
            geometryLocked = VisionFrameGeometry(width: width, height: height, mirrored: mirrored)
        }

        let plan = self.plan
        syncModels(to: plan)
        guard plan.wantsCapture else { return }

        let now = ContinuousClock.now
        let due = gate.dueTopics(for: plan, at: now)
        let modelsDue = due.intersection(VisionModelTopics)
        guard !modelsDue.isEmpty || due.contains(.signals) else { return }

        let header = visionHeader(seq: frameSeq,
                                  ts: ts,
                                  deviceID: deviceID,
                                  width: width,
                                  height: height)

        var bundle = VisionFrameBundle(header: header)
        if !modelsDue.isEmpty {
            bundle = analyzer.analyze(pixelBuffer, run: modelsDue, header: header, mirrored: mirrored)
            bump { $0.analyzed &+= 1 }
            carryForward(bundle)
            // One publish per topic that actually ran. A model that ran and
            // saw nothing still publishes — an empty frame means "nothing
            // detected", which is a different message from no message at all.
            //
            // A FEEDER is the exception and does not publish at all: its model
            // runs only to give `vision.signals.v1` something to compute over,
            // and nothing subscribes to its topic. See `VisionPlanner`.
            for topic in modelsDue.sorted() {
                guard plan.topics[topic]?.publishes == true else { continue }
                guard let payload = bundle.payload(for: topic) else { continue }
                emit(topic, payload)
            }
        }

        publishSignalsIfDue(due, header: header)

        let latest = carriedBundle(header: header)
        let sinks = lock.withLock { () -> [AsyncStream<VisionFrameBundle>.Continuation] in
            latestLocked = latest
            return Array(frameSinksLocked.values)
        }
        // Nothing built for nobody: with no overlay attached this loop does
        // not run and the bundle is never yielded anywhere.
        for sink in sinks { sink.yield(latest) }
    }

    /// Signals are derived from the **carried** bundle: this frame's fresh
    /// outputs, falling back to the most recent output of any model that is
    /// still active but was not due on this tick.
    ///
    /// That fallback is what makes the contract's presence rule true. The rule
    /// is "a field is absent when the model that feeds it is not running" — so
    /// `ear_l` must be present on every signals message while faces are
    /// running, not just on the ticks where the face gate happened to fire.
    /// Reading only this frame would make every field blink in and out at the
    /// beat frequency between two independent rate gates, and a consumer
    /// cannot tell that apart from "the model was just switched off".
    ///
    /// Staleness is bounded by the feeding topic's own requested interval,
    /// which is the rate its requester chose. Signals for a model that is not
    /// active are absent, because `releaseCarried` clears its carried value
    /// the moment the model goes away.
    private func publishSignalsIfDue(_ due: Set<VisionTopic>, header: VCTHeader) {
        guard due.contains(.signals), let signalsComputer else { return }
        let merged = carriedBundle(header: header)
        // Nothing has been computed yet by any model, so there is nothing to
        // derive. An all-absent Signals message would look like a working tier
        // with nothing to say, which is the one reading the contract forbids.
        guard !merged.produced.isEmpty else { return }
        guard var signals = signalsComputer(merged) else { return }
        // This frame's header always wins, whatever the computer put there —
        // every topic derived from one frame shares one `seq`.
        signals.header = header
        guard let payload = try? signals.serializedData() else { return }
        emit(.signals, payload)
    }

    private func carryForward(_ bundle: VisionFrameBundle) {
        if let face = bundle.face {
            carriedFace = face
            carriedFaceLayout = bundle.faceLayout
        }
        if let hands = bundle.hands { carriedHands = hands }
        if let body = bundle.body { carriedBody = body }
        if let segmentation = bundle.segmentation { carriedSegmentation = segmentation }
    }

    private func carriedBundle(header: VCTHeader) -> VisionFrameBundle {
        VisionFrameBundle(header: header,
                          face: carriedFace,
                          faceLayout: carriedFaceLayout,
                          hands: carriedHands,
                          body: carriedBody,
                          segmentation: carriedSegmentation)
    }

    /// Constructs and releases models so exactly the plan's set exists.
    /// Idempotent and cheap when nothing changed, which is why the frame path
    /// can call it on every frame as well as `applyPlan` dispatching it.
    private func syncModels(to plan: VisionPlan) {
        let change = analyzer.setActiveModels(plan.models)
        guard !change.isEmpty else { return }
        // A released topic forgets its schedule, so re-requesting it later
        // fires on the first frame instead of waiting out an interval measured
        // from before it was switched off.
        gate.forget(change.released)
        for topic in change.released { releaseCarried(topic) }
    }

    private func releaseCarried(_ topic: VisionTopic) {
        switch topic {
        case .face:
            carriedFace = nil
            carriedFaceLayout = nil
        case .hands: carriedHands = nil
        case .bodyPose: carriedBody = nil
        case .segmentation: carriedSegmentation = nil
        case .signals: break
        }
    }

    // MARK: - Counters

    func bump(_ change: (inout VisionCounters) -> Void) {
        lock.lock()
        change(&countersLocked)
        lock.unlock()
    }
}
