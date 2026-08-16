import Foundation
import VCKStubs
import VCPluginSDK

/// The publish seam.
///
/// `VCHost` conforms below. A test uses a spy, because `VCHost` can only be
/// built by `connect()`, which dials a real unix socket.
public protocol VisionPublisher: Sendable {
    /// Must carry a deadline. `VCHost.publish` puts one on every unary call
    /// (5 s) precisely because neither `Publish` nor `Alert` has one by
    /// default and both can block indefinitely against a wedged core — a
    /// provider publishing at frame rate would pile up tasks until the process
    /// died.
    func publish(topic: String, payload: Data) async throws
}

/// `VCHost.publish(topic:payload:)` already matches, and already deadlines.
extension VCHost: VisionPublisher {}

/// The vision provider: the control plane, the capture lifecycle, and the one
/// public surface the HTTP layer talks to.
///
/// ## The two mechanisms it merges
///
/// * **Kernel demand** (`_core.demand.v1`) is truthful about **liveness**. Zero
///   subscribers closes the camera, always. It is authoritative state, not a
///   delta, so every event overwrites and a full burst arrives on reconnect.
/// * **`vision.request.v1`** is truthful about **intent**. Desired state,
///   latest-wins per requester, expiring by TTL, so a detector switched off in
///   its own UI stops the models it was driving without exiting its process.
///
/// A topic runs iff both say yes. Neither alone is enough, and the failure
/// modes are opposite: demand without a request is a misconfigured consumer
/// (loudly warned about), a request without demand is work nobody would
/// receive (silently ignored, because the floor is not negotiable).
///
/// Nothing here ever exits the process. A denied camera, a missing camera, a
/// failed publish — all degrade in place and retry, because core charges any
/// unrequested exit as a failed start and five park the plugin in
/// `StateFailed`.
public actor VisionProvider {
    /// How often the TTL sweep and plan recompute run. Well inside the 30 s
    /// default TTL, so a wedged consumer's grip on the camera is released
    /// within a second of expiring rather than at the next frame — which for a
    /// stopped session would be never.
    private static let tickInterval: Duration = .seconds(1)

    /// How long to wait before asking a denied or absent camera again. The
    /// tick above runs every second; retrying the TCC path that often would
    /// spin the log and, on `notDetermined`, re-prompt.
    private static let cameraRetryInterval: Duration = .seconds(30)

    /// Bound on the publish queue. Deep enough to absorb a slow RPC, shallow
    /// enough that a wedged core costs bounded memory instead of unbounded —
    /// `bufferingNewest` drops the OLDEST, which is the right end to lose for
    /// a stream of frames where the freshest one is the only one that matters.
    private static let publishQueueDepth = 64

    // MARK: Public, nonisolated surface

    /// `/preview.mjpeg`'s frame source, and where `latestJPEG` lives. An actor
    /// of its own, so the HTTP layer talks to it directly without going
    /// through this one.
    public nonisolated let preview = PreviewStream()

    // MARK: Wiring

    /// `CameraSession` carries an `@unchecked Sendable` conformance under a
    /// manual-synchronization argument documented on that type: every mutation
    /// is either dispatched onto its own serial `frameQueue` or taken under
    /// its own lock. `nonisolated` because the frame path and the readout both
    /// reach it without hopping onto this actor.
    private nonisolated let camera: any VisionCameraControlling
    private nonisolated let processor: FrameProcessor
    private let publisher: any VisionPublisher
    private let signalsAvailable: Bool
    private let outbound: AsyncStream<OutboundMessage>.Continuation
    private let outboundStream: AsyncStream<OutboundMessage>

    // MARK: Control-plane state

    private var requests = RequestRegistry()
    private var demand = DemandTable()
    private var plan: VisionPlan = .idle
    /// Topic names currently in the warning state, so the line is logged on
    /// the transition into it rather than once a second forever.
    private var warnedTopics: Set<String> = []

    private var capturing = false
    /// The rate actually pushed to the device, so a steady session does not
    /// re-lock it every reconcile. Cleared on stop: a session that restarts
    /// must apply its rate again rather than inherit this one.
    private var appliedFrameRate: Int?
    private var permission: VisionPermission = .unknown
    private var nextCameraAttempt: ContinuousClock.Instant?
    private var cameraBusy = false
    private var reconcilePending = false

    private var tasks: [Task<Void, Never>] = []
    private var stopped = false

    struct OutboundMessage: Sendable {
        let topic: String
        let payload: Data
    }

    /// - Parameters:
    ///   - publisher: `VCHost` in production.
    ///   - signalsComputer: the `vision.signals.v1` math, which lives in the
    ///     `VCGeometry` target. `nil` means signals are never published, which
    ///     `/api/state` reports as `signalsAvailable: false` rather than
    ///     hiding.
    ///   - analyzer: the inference seam. Defaults to the real Vision
    ///     framework; a test passes a double.
    ///   - camera: defaults to a real `AVCaptureSession` wrapper.
    public init(publisher: any VisionPublisher,
                signalsComputer: VisionSignalsComputer? = nil,
                analyzer: (any VisionAnalyzing)? = nil,
                camera: (any VisionCameraControlling)? = nil) {
        let session = camera ?? CameraSession()
        let (stream, continuation) = AsyncStream<OutboundMessage>.makeStream(
            of: OutboundMessage.self,
            bufferingPolicy: .bufferingNewest(Self.publishQueueDepth)
        )
        let preview = self.preview
        let processor = FrameProcessor(
            analyzer: analyzer ?? AppleVisionAnalyzer(),
            queue: session.frameQueue,
            preview: preview,
            signalsComputer: signalsComputer,
            emit: { topic, payload in
                // Never awaits the RPC: the camera callback must not stall
                // behind a wedged core. `yield` on a bounded stream either
                // enqueues or drops, and never blocks.
                continuation.yield(OutboundMessage(topic: topic.name, payload: payload))
            }
        )
        session.attach(processor)

        self.camera = session
        self.processor = processor
        self.publisher = publisher
        self.signalsAvailable = signalsComputer != nil
        self.outbound = continuation
        self.outboundStream = stream
    }

    // MARK: - Lifecycle

    /// Starts the event loop, the TTL ticker and the publish pump.
    ///
    /// Non-blocking: the composition root calls this and then parks on
    /// `host.waitForShutdown()`. `events` is `VCHost.events()`, which finishes
    /// when the host shuts down — so the event loop ending is itself the
    /// shutdown signal.
    public func start(events: AsyncStream<VCEvent>) {
        guard !stopped, tasks.isEmpty else { return }
        tasks.append(Task { await self.runPublishPump() })
        tasks.append(Task { await self.runTicker() })
        tasks.append(Task { await self.runEventLoop(events) })
    }

    /// Closes the camera, stops the pumps and detaches every preview client.
    /// Safe to call twice; safe to call before `start`.
    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        camera.stop()
        capturing = false
        plan = .idle
        processor.applyPlan(.idle)
        processor.finishFrameStreams()
        outbound.finish()
        await preview.detachAll()
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    private func runEventLoop(_ events: AsyncStream<VCEvent>) async {
        for await event in events {
            await handle(event)
        }
        // The stream finishing means the host is going down. Close the camera
        // rather than leave the LED on behind a dead control plane.
        await shutdown()
    }

    private func runTicker() async {
        while !stopped, !Task.isCancelled {
            try? await Task.sleep(for: Self.tickInterval)
            guard !stopped, !Task.isCancelled else { return }
            await reconcile()
        }
    }

    /// One serial consumer, so publishes cannot interleave into an unbounded
    /// pile of tasks. Each `publish` carries the SDK's 5 s deadline, so a
    /// wedged core costs at most that per message and the bounded stream sheds
    /// the rest.
    private func runPublishPump() async {
        for await message in outboundStream {
            do {
                try await publisher.publish(topic: message.topic, payload: message.payload)
                processor.bump { $0.published &+= 1 }
            } catch {
                processor.bump { $0.dropped &+= 1 }
                // Not fatal and not worth a line per frame: a publish failing
                // while core restarts is expected, and the counter in
                // /api/state is the durable record.
            }
        }
    }

    // MARK: - Events

    /// Routes one bus event. Public so a test can drive the control plane
    /// without a kernel.
    public func handle(_ event: VCEvent) async {
        switch event.topic {
        case VCTopicDemand:
            guard demand.apply(payload: event.payload) != nil else { return }
            await reconcile()
        case VisionRequestTopic:
            guard let message = try? VCTRequest(serializedBytes: event.payload) else {
                visionLog("undecodable \(VisionRequestTopic) payload (\(event.payload.count) bytes); ignoring")
                return
            }
            guard requests.apply(message, at: ContinuousClock.now) else { return }
            await reconcile()
        default:
            // Nothing else is subscribed, so anything else is core sending a
            // topic this plugin's manifest does not name.
            break
        }
    }

    // MARK: - Reconciliation

    /// Recomputes the plan from the two mechanisms and moves the world to
    /// match it. Idempotent: called on every event and every tick.
    public func reconcile() async {
        let now = ContinuousClock.now
        let expired = requests.expire(at: now)
        for requester in expired {
            visionLog("request expired requester=\(requester); its topics stop unless someone else asked")
        }

        let next = VisionPlanner.plan(requests: requests, demand: demand, at: now)
        if next != plan {
            logPlanChange(from: plan, to: next)
            plan = next
            processor.applyPlan(next)
        }
        logWarnings(next.warnings)
        await reconcileCamera()
    }

    /// The camera half. Serialized against itself with `cameraBusy`, because
    /// `camera.start()` suspends (it may be showing a TCC prompt) and actor
    /// isolation is released across that suspension — two concurrent
    /// reconciles would otherwise both decide to open the camera.
    private func reconcileCamera() async {
        guard !cameraBusy else {
            reconcilePending = true
            return
        }
        cameraBusy = true

        if plan.wantsCapture, !stopped {
            if !capturing, shouldAttemptCamera() {
                let result = await camera.start()
                switch result {
                case .started:
                    capturing = true
                    permission = .granted
                    nextCameraAttempt = nil
                    visionLog("capture started fps=\(plan.captureFPS) "
                              + "topics=[\(plan.runningTopics.map(\.name).joined(separator: ","))]")
                case .denied:
                    permission = .denied
                    // Degrade, never exit: an unrequested exit is charged as a
                    // failed start and five park the plugin in StateFailed.
                    // The user may grant access at any moment, so keep asking
                    // — slowly.
                    visionLog("camera access denied; degrading and retrying in "
                              + "\(visionSeconds(Self.cameraRetryInterval))s")
                    nextCameraAttempt = ContinuousClock.now + Self.cameraRetryInterval
                case .noDevice:
                    permission = .noDevice
                    visionLog("no camera device; retrying in \(visionSeconds(Self.cameraRetryInterval))s")
                    nextCameraAttempt = ContinuousClock.now + Self.cameraRetryInterval
                }
            }
            // Only on change. `reconcile` runs on every bus event and on a 1s
            // tick, and `setFrameRate` takes `device.lockForConfiguration()` —
            // rewriting `activeVideoMinFrameDuration` once a second on a
            // steady session is a lock taken against a running capture for no
            // reason. Mirrors the plan-changed guard above.
            if capturing, appliedFrameRate != plan.captureFPS {
                camera.setFrameRate(plan.captureFPS)
                appliedFrameRate = plan.captureFPS
            }
        } else if capturing {
            camera.stop()
            capturing = false
            appliedFrameRate = nil
            visionLog("capture stopped — no topic has both a subscriber and a live request")
        }

        cameraBusy = false
        if reconcilePending {
            reconcilePending = false
            Task { await self.reconcileCamera() }
        }
    }

    private func shouldAttemptCamera() -> Bool {
        guard let next = nextCameraAttempt else { return true }
        return ContinuousClock.now >= next
    }

    private func logPlanChange(from old: VisionPlan, to new: VisionPlan) {
        for topic in new.runningTopics {
            let plan = new.topics[topic]!
            guard old.topics[topic] != plan else { continue }
            visionLog("running \(topic.name) fps=\(plan.fps) subscribers=\(plan.subscribers) "
                      + "requesters=[\(plan.requesters.joined(separator: ","))]")
        }
        for topic in old.runningTopics where new.topics[topic] == nil {
            visionLog("stopping \(topic.name)")
        }
    }

    /// Logs §5.3's warning on the transition into it, and its recovery on the
    /// way out. Once a second forever would bury it; never would leave the
    /// single most likely consumer misconfiguration completely silent.
    private func logWarnings(_ warnings: [VisionWarning]) {
        let current = Set(warnings.map(\.topic))
        for warning in warnings where !warnedTopics.contains(warning.topic) {
            visionLog(warning.message)
        }
        for topic in warnedTopics.subtracting(current).sorted() {
            visionLog("subscriber with no request resolved topic=\(topic)")
        }
        warnedTopics = current
    }

    // MARK: - Readouts for the HTTP layer

    /// The whole `/api/state` body.
    public func snapshot() async -> VisionSnapshot {
        let now = ContinuousClock.now
        let active = await processor.activeModels()
        let intent = requests.intent(at: now)
        return VisionSnapshot(
            capturing: capturing,
            captureFPS: capturing ? plan.captureFPS : 0,
            permission: permission,
            device: capturing ? camera.currentCamera : nil,
            cameras: camera.availableCameras(),
            geometry: capturing ? processor.geometry : VisionFrameGeometry(),
            // Every topic, running or not — see `VisionTopicReport`.
            topics: VisionTopic.allCases.sorted().map { topic in
                let entry = plan.topics[topic]
                return VisionTopicReport(
                    topic: topic.name,
                    running: entry != nil,
                    fps: entry?.fps ?? 0,
                    subscribers: demand.subscribers(topic),
                    requesters: intent[topic]?.requesters ?? [],
                    model: topic.model
                )
            },
            activeModels: active.sorted().compactMap(\.model),
            requesters: requests.live(at: now).map {
                VisionRequesterState(requester: $0.requester,
                                     topics: $0.topicNames,
                                     fps: $0.fps,
                                     expiresIn: $0.remainingSeconds(at: now))
            },
            warnings: plan.warnings,
            counters: processor.counters,
            signalsAvailable: signalsAvailable
        )
    }

    /// Every camera the machine has. Cheap and prompt-free — discovery reports
    /// names without a TCC prompt; only opening one prompts.
    public nonisolated func cameras() -> [VisionCamera] {
        camera.availableCameras()
    }

    /// A fan-out of every analysed frame, for a `/api/events` overlay stream.
    /// Idles for free when nothing is attached.
    public nonisolated func frames() -> AsyncStream<VisionFrameBundle> {
        processor.frames()
    }

    /// Switches camera. `nil` restores "whatever the system default is".
    ///
    /// Returns `false` for an id no attached device has, so the HTTP layer can
    /// answer 404 instead of silently doing nothing. A live session is torn
    /// down and reopened, which also makes the switch visible to consumers as
    /// a `Header.device_id` change.
    @discardableResult
    public func selectCamera(id: String?) async -> Bool {
        if let id, !camera.availableCameras().contains(where: { $0.id == id }) {
            return false
        }
        camera.setPreferredDevice(id: id)
        let wasCapturing = capturing
        camera.stop()
        capturing = false
        await camera.reset()
        // A device the user just picked deserves an immediate attempt, even if
        // a previous one failed and armed the retry timer.
        nextCameraAttempt = nil
        if wasCapturing || plan.wantsCapture { await reconcileCamera() }
        return true
    }

    /// The most recent landmarks, for the UI overlay. Carried forward per
    /// model, so a topic running at 2 fps still has a value here between its
    /// frames; a model that has been released contributes nothing.
    public nonisolated func latestFrames() -> VisionFrameBundle? {
        processor.latestFrames
    }

    /// The current plan — which topics run, at what rate, for whom.
    public func currentPlan() -> VisionPlan { plan }

    /// Test-support entry point: the frame path, so a test can deliver a frame
    /// through the real publish route without a camera. Production code has no
    /// reason to reach past this actor into the processor.
    var frameProcessorForTesting: FrameProcessor { processor }

    /// One JPEG of what the camera currently sees, encoding on demand rather
    /// than keeping the encoder running for nobody.
    ///
    /// Returns `nil` when the session is closed (there is nothing to see) or
    /// when no frame arrived inside `timeout`.
    public func stillJPEG(timeout: Duration = .milliseconds(500)) async -> Data? {
        guard capturing else { return nil }
        let before = await preview.latestJPEG
        await preview.requestStill()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            let latest = await preview.latestJPEG
            if let latest, latest != before { return latest }
        }
        return await preview.latestJPEG
    }
}
