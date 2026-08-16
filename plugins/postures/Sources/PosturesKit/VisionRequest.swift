import Foundation
import VCKStubs
import VCPluginSDK

/// The subset of `VCHost` this plugin calls. A unit-testing seam and nothing
/// more: `VCHost` dials a real gRPC socket in `connect()` and cannot be
/// constructed in a test, so tests inject a spy conforming to this instead.
/// `VCHost` needs no changes — both signatures already match.
public protocol PostureHost: Sendable {
    func alert(_ a: VCAlert) async throws
    func publish(topic: String, payload: Data) async throws
}

extension VCHost: PostureHost {}

/// What postures asks vision for, and the constants that make the ask
/// truthful.
///
/// Subscribing is only half of it. Demand governs whether vision MAY run a
/// model; the request union governs whether it DOES. A consumer that
/// declares `subscribes: [vision.body_pose.v1]` and never publishes a request
/// sits there receiving nothing at all, which is indistinguishable from a
/// broken bus — spec §5.3 calls this the single most likely way to wire a new
/// consumer up wrong. Hence this type, and hence `/api/state` reporting when
/// the request was last asserted.
public enum VisionRequest {
    /// Declared in `manifest.yaml` under `publishes`. Publishing an
    /// undeclared topic is a logged error and a DROPPED message, which here
    /// would silently mean "vision never runs the model I need".
    public static let topic = "vision.request.v1"

    public static let bodyPoseTopic = "vision.body_pose.v1"
    public static let signalsTopic = "vision.signals.v1"

    /// Both subscribed topics, because both are needed and §5.3's rule is
    /// per topic: `vision.signals.v1` is where `shoulder_angle` and
    /// `neck_forward` actually come from, and requesting only body pose would
    /// leave this plugin subscribed to a topic nobody asked to be produced.
    /// The two share one Vision request on the provider side — signals are
    /// "free — pure math" over landmarks already computed — so naming both
    /// costs no extra inference.
    public static let topics = [bodyPoseTopic, signalsTopic]

    /// Two frames a second. Posture is measured in minutes; the dwell default
    /// is 120 s, so 2 fps still gives 240 samples per decision. Vision runs
    /// `max()` across requesters, so this is a floor for everyone else's
    /// benefit, never a cap on theirs.
    public static let fps: UInt32 = 2

    /// Matches the spec's default. A request older than this is dropped by
    /// vision, which is what makes a wedged consumer stop holding the camera
    /// open.
    public static let ttlSeconds: UInt32 = 30

    /// Well inside `ttlSeconds`, so two consecutive lost heartbeats still do
    /// not expire the request.
    public static let heartbeat: TimeInterval = 10

    /// Desired state, latest-wins per `requester`.
    ///
    /// Disabled sends `{topics: []}` rather than sending nothing: silence
    /// only expires after the TTL and, until then, leaves vision running a
    /// model for a feature the user just switched off. An explicit empty list
    /// is what makes "user disables postures" close the camera immediately
    /// (spec §5.2) even though this process stays up and subscribed.
    ///
    /// `fps` is sent even when retracting. It is meaningless with no topics,
    /// but `0` is NOT neutral — the spec reads an absent or zero `fps` as the
    /// default 15 — so sending the real number is the option with no way to
    /// be misread.
    public static func message(requester: String, enabled: Bool) -> VCTRequest {
        var r = VCTRequest()
        r.requester = requester
        r.topics = enabled ? topics : []
        r.fps = fps
        r.ttlS = ttlSeconds
        return r
    }

    public static func payload(requester: String, enabled: Bool) throws -> Data {
        try message(requester: requester, enabled: enabled).serializedData()
    }
}

/// Owns the `vision.request.v1` lifecycle: assert on enable, retract on
/// disable, and re-assert on every reconnect and on a heartbeat.
///
/// **How a plugin observes a reconnect.** It does not, directly — `VCHost`
/// exposes one continuous event stream across sessions and nothing that says
/// "the Register stream just came back". The observable proxy is the demand
/// burst: `Bus.Subscribe` announces the current subscriber count for every
/// topic this plugin PUBLISHES the moment a Register stream attaches, so a
/// `_core.demand.v1` event is core telling us, in effect, that we have a live
/// stream again. `PostureMonitor` routes those here. The 10 s heartbeat is
/// the belt to that braces: even if the burst were ever missed, the request
/// is re-asserted twice per TTL window.
public actor VisionRequester {
    private let requester: String
    private let heartbeatInterval: TimeInterval
    private var host: (any PostureHost)?
    private var enabled = false
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    /// Observability for `/api/state` — the readout spec §5.3 asks for, so a
    /// mis-wired consumer is visible instead of merely silent.
    public private(set) var lastAssertedAt: Date?
    public private(set) var lastAssertedTopics: [String] = []
    public private(set) var lastError: String?
    public private(set) var assertCount = 0

    public init(requester: String, heartbeatInterval: TimeInterval = VisionRequest.heartbeat) {
        self.requester = requester
        self.heartbeatInterval = heartbeatInterval
    }

    /// Called once, from the composition root, right after `VCHost.connect()`
    /// returns — no live host exists before that, because routes (and the
    /// objects they close over) must be registered first.
    public func attach(host: any PostureHost) {
        self.host = host
    }

    /// Sets the desired state and asserts it immediately.
    public func setEnabled(_ on: Bool) async {
        enabled = on
        await assert()
    }

    /// Re-publishes the current desired state. Idempotent by construction:
    /// the request topic is latest-wins per requester, so an extra assertion
    /// costs one small message and changes nothing.
    public func reassert() async {
        await assert()
    }

    public func startHeartbeat() {
        guard heartbeatTask == nil, !stopped else { return }
        heartbeatTask = Task { [heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(heartbeatInterval))
                if Task.isCancelled { return }
                await self.assert()
            }
        }
    }

    /// Retracts the request and stops the heartbeat.
    ///
    /// Best-effort on the way down: core may already be tearing the socket
    /// down, in which case the publish fails and the demand floor closes the
    /// camera anyway when this process's stream drops. Worth attempting
    /// regardless — when core is shutting down cleanly and vision is still
    /// up, this is what turns the LED off a beat sooner.
    public func stop() async {
        stopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        enabled = false
        await assert()
        host = nil
    }

    private func assert() async {
        guard let host else {
            lastError = "no host attached yet"
            return
        }
        let payload: Data
        do {
            payload = try VisionRequest.payload(requester: requester, enabled: enabled)
        } catch {
            // Serializing a four-field message cannot realistically fail, but
            // trapping here would be an unrequested exit for a message we
            // could simply retry on the next heartbeat.
            lastError = "could not encode request: \(error)"
            posturesLog("could not encode vision request: \(error)")
            return
        }
        do {
            try await host.publish(topic: VisionRequest.topic, payload: payload)
            lastAssertedAt = Date()
            lastAssertedTopics = enabled ? VisionRequest.topics : []
            lastError = nil
            assertCount += 1
        } catch {
            // Never fatal, and deliberately not retried in a tight loop: core
            // may simply be mid-reconnect, in which case the next heartbeat
            // (or the demand burst that follows the reconnect) carries it.
            lastError = "\(error)"
            posturesLog("publishing \(VisionRequest.topic) failed: \(error)")
        }
    }
}

/// `fputs`, never `FileHandle.standardError.write(_:)`: the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown —
/// `supervisor.go` then charges the resulting abort as a failed start.
func posturesLog(_ message: String) {
    fputs("postures: \(message)\n", stderr)
}
