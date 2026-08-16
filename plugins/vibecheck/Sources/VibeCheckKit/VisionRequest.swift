import Foundation
import VCKStubs

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — see the identical
/// rule and reasoning in every other file of this package.
private func requestLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// Told whenever this plugin's config changes in a way that could change
/// which `vision.*` topics it needs. Exists so `DetectionEngine` can drive
/// the request without importing the publisher: the engine owns "what the
/// user asked for", `VisionRequest` owns "what we therefore ask the provider
/// for", and the seam between them is one method and a spy in tests.
public protocol VisionDemandSink: Sendable {
    func configChanged(_ config: VibeCheckConfig) async
}

/// Publishes `vision.request.v1` — this plugin's half of the control plane
/// the vision provider runs on.
///
/// ## Why this exists at all
///
/// The kernel's demand refcount already closes the camera when nothing
/// subscribes, and that is the privacy FLOOR. What it cannot know is INTENT:
/// a user who switches detection off in this plugin's own UI leaves the
/// process up and still subscribed to `vision.face.v1`, so demand stays at 1
/// and the camera LED stays on. Publishing `{topics: []}` is what closes
/// that gap — the provider destroys the models nobody wants and, when every
/// consumer has retracted, stops the capture session. **This is the whole
/// point of the redesign: a disabled detector must stop costing camera and
/// ANE**, and it is the only mechanism that makes that true without a kernel
/// change.
///
/// ## Why it repeats itself
///
/// The request is desired state with a TTL, latest-wins per requester, and
/// bus events are ephemeral — no persistence, no replay. A request published
/// while the provider happened to be restarting is simply gone, and a
/// request published once and never repeated expires after `ttlSeconds`. So
/// it is asserted from three places, all of which are needed:
///
///  * on every config change, so a toggle takes effect immediately;
///  * on every `_core.demand.v1` announcement, which is the only reconnect
///    signal a plugin can observe (see `VisionIntake`);
///  * on a 10s heartbeat, comfortably inside the 30s TTL, which is the
///    backstop for anything the other two miss.
public actor VisionRequest: VisionDemandSink {
    /// Wire topic name. Declared in `manifest.yaml`'s `publishes` — an
    /// undeclared topic is a logged error and a DROPPED message, which here
    /// would silently mean "the provider never runs the model we need".
    public static let topic = "vision.request.v1"
    /// `Request.requester`. Self-asserted and not authenticated (the bus
    /// carries no publisher identity), and must equal this plugin's manifest
    /// id or the provider's latest-wins map keys our retraction separately
    /// from our request and never lets go of the models.
    public static let requester = "vibecheck"
    /// Detection ran at a 15fps Vision throttle before the cutover; asking
    /// the provider for the same rate keeps the dwell arithmetic — which is
    /// measured in seconds of continuous presence, not in frames — behaving
    /// as it did.
    public static let fps: UInt32 = 15
    /// Seconds the provider keeps this request live without re-assertion.
    public static let ttlSeconds: UInt32 = 30
    /// Comfortably inside `ttlSeconds`: three attempts before a request
    /// could expire, so two lost publishes in a row still cost nothing.
    public static let heartbeat: Duration = .seconds(10)

    private let joiner: VisionFrameJoiner
    private var host: (any AlertHost)?
    private var desired: Set<VisionTopic> = []
    /// What the last logged assertion said, so the 10s heartbeat is silent
    /// while the request is unchanged. `nil` until the first publish, so the
    /// first assertion always logs — including the empty one.
    private var lastLoggedTopics: [String]?
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    public init(joiner: VisionFrameJoiner) {
        self.joiner = joiner
    }

    /// The topics a given config implies, as a pure function so
    /// `GET /api/state` can report them without asking this actor and
    /// without the two answers ever disagreeing.
    ///
    /// An empty result is meaningful and is published as such: it retracts
    /// this plugin's demand entirely. Both switches produce it — detection
    /// turned off, and detection on with every behaviour unticked — because
    /// both mean the same thing to the provider.
    public static func topics(for config: VibeCheckConfig) -> Set<VisionTopic> {
        guard config.enabled else { return [] }
        let behaviors = config.enabledBehaviors.compactMap(BFRBBehavior.init(rawValue:))
        return behaviors.reduce(into: Set<VisionTopic>()) { $0.formUnion($1.requiredVisionTopics) }
    }

    /// Called once, from `main.swift`, right after `VCHost.connect()`
    /// returns — the same ordering constraint `HostSink.attach(host:)` has,
    /// and for the same reason: routes (and everything they close over) must
    /// exist before `connect()` can be called at all.
    public func attach(host: any AlertHost) {
        self.host = host
    }

    public func currentTopics() -> [String] {
        desired.map(\.rawValue).sorted()
    }

    // MARK: - VisionDemandSink

    public func configChanged(_ config: VibeCheckConfig) async {
        await set(Self.topics(for: config), reason: "config change")
    }

    // MARK: - Assertion

    /// Re-publishes the current desired state unchanged. Used by the
    /// reconnect path; a no-op assertion is still worth sending, because the
    /// provider may have restarted and forgotten us.
    public func reassert(reason: String) async {
        guard !stopped else { return }
        await publish(reason: reason)
    }

    private func set(_ topics: Set<VisionTopic>, reason: String) async {
        let changed = topics != desired
        desired = topics
        if changed {
            // The join's completeness rule must track what we asked for.
            // Requiring a topic nobody requested wedges the join forever;
            // requiring less than we requested evaluates hair-pulling
            // against a mask that never arrived.
            await joiner.setRequired(topics)
        }
        await publish(reason: reason)
        // A retracted request has nothing to keep alive — the provider
        // treats an expired empty request and no request identically — so
        // the heartbeat runs only while something is actually wanted rather
        // than chattering on the bus forever for a switched-off detector.
        if desired.isEmpty {
            stopHeartbeat()
        } else {
            startHeartbeat()
        }
    }

    /// Publishes the retraction and stops the heartbeat. Registered as a
    /// `VCHost` shutdown hook so a graceful stop closes the camera at once
    /// instead of leaving the provider to time us out 30s later. The demand
    /// floor would close it regardless once this process is gone; this is
    /// the difference between "immediately" and "eventually".
    public func retract() async {
        stopHeartbeat()
        desired = []
        await joiner.setRequired([])
        await publish(reason: "shutdown")
        // Set only after the last publish: `stopped` gates `reassert`, so
        // flipping it first would make this method silently do nothing if a
        // demand announcement raced it.
        stopped = true
    }

    private func publish(reason: String) async {
        guard let host else {
            requestLog("vision.request.v1 not published (\(reason)): no host attached yet")
            return
        }
        var request = VCTRequest()
        request.requester = Self.requester
        request.topics = desired.map(\.rawValue).sorted()
        request.fps = Self.fps
        request.ttlS = Self.ttlSeconds
        do {
            let payload = try request.serializedBytes() as Data
            try await host.publish(topic: Self.topic, payload: payload)
            // Log the transition, not the heartbeat. The heartbeat re-asserts
            // an unchanged request every 10s — logging each one buries the
            // enable/disable transitions that actually explain why the camera
            // is on under ~8,600 identical lines a day. The provider side
            // already logs only on change; this matches it.
            if request.topics != lastLoggedTopics {
                requestLog("vision.request.v1 <- \(request.topics) @\(Self.fps)fps (\(reason))")
                lastLoggedTopics = request.topics
            }
        } catch {
            // Never fatal, and never a reason to stop trying: core may be
            // mid-reconnect, in which case the heartbeat below is exactly
            // what recovers it. Nothing in this plugin terminates the
            // process — an unrequested exit is charged as a failed start.
            requestLog("vision.request.v1 publish failed (\(reason)): \(error)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VisionRequest.heartbeat)
                guard !Task.isCancelled else { return }
                await self?.reassert(reason: "heartbeat")
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}
