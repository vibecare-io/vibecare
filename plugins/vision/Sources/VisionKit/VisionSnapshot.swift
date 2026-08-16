import Foundation

/// Where the camera-permission conversation got to. `unknown` is not a
/// `CameraStartResult` case on purpose: "never asked" is a different state
/// from "asked and refused", and the provider only ever asks when a plan
/// actually wants the camera — so a machine where nobody has requested
/// anything must never have triggered a TCC prompt.
public enum VisionPermission: String, Sendable, Codable {
    case unknown
    case granted
    case denied
    case noDevice
}

/// One publishable topic and everything decided about it.
///
/// **Every topic appears, running or not.** "hands is not running" is exactly
/// what a user checking the privacy readout came to find out, and a topic that
/// vanishes from the list is indistinguishable from a topic that was never
/// implemented.
public struct VisionTopicReport: Sendable, Equatable, Codable {
    public let topic: String
    /// Whether a model is running (or, for `vision.signals.v1`, whether the
    /// topic is being published).
    public let running: Bool
    /// Effective rate — `max()` across requesters, capped at 30 — and `0` when
    /// the topic is not running.
    public let fps: Int
    /// The kernel's demand refcount: the liveness half, and the privacy floor.
    /// Zero means the topic may not run at all, whatever anyone requested.
    public let subscribers: Int
    /// Plugin ids from live `vision.request.v1` messages naming this topic:
    /// the intent half. **Self-asserted and not authenticated** — the bus
    /// event carries no publisher id, so this is a claim, not a proof. It is
    /// still the most useful thing the readout can say, and the demand floor
    /// is what actually gates the camera.
    ///
    /// Populated even when the topic is NOT running, because "somebody asked
    /// and it still is not running" is the interesting case.
    public let requesters: [String]
    /// The `VNRequest` this topic costs, or `nil` for one that costs no
    /// inference.
    public let model: String?

    public init(topic: String,
                running: Bool,
                fps: Int,
                subscribers: Int,
                requesters: [String],
                model: String?) {
        self.topic = topic
        self.running = running
        self.fps = fps
        self.subscribers = subscribers
        self.requesters = requesters
        self.model = model
    }
}

/// One live requester's desired state.
public struct VisionRequesterState: Sendable, Equatable, Codable {
    public let requester: String
    public let topics: [String]
    public let fps: Int
    /// Seconds until this request lapses without a re-assertion. A consumer
    /// heartbeating properly sits near its full TTL; one counting down towards
    /// zero has wedged, and that is worth being able to see.
    public let expiresIn: TimeInterval

    public init(requester: String, topics: [String], fps: Int, expiresIn: TimeInterval) {
        self.requester = requester
        self.topics = topics
        self.fps = fps
        self.expiresIn = expiresIn
    }
}

/// Everything `GET /api/state` reports — and, per the vision design §7, the
/// plugin's privacy surface. `/api/*` is the real interface and the HTML is
/// its first consumer, so this type is the contract and the page is a
/// rendering of it.
///
/// `warnings` is load-bearing, not decoration: a consumer that subscribes
/// without ever publishing a request receives nothing at all and looks exactly
/// like a broken bus, and this list is the only place that says so.
public struct VisionSnapshot: Sendable, Equatable, Codable {
    /// Whether the capture session is open — i.e. whether the LED is on. This,
    /// not the request union, is what the LED follows, so it is what a UI's
    /// "the camera is on" claim must be keyed to.
    public let capturing: Bool
    /// The rate the session runs at, `max()` of the per-topic rates capped at
    /// 30. `0` when nothing is running.
    public let captureFPS: Int
    public let permission: VisionPermission
    /// The camera currently open, or `nil` when the session is closed.
    public let device: VisionCamera?
    /// Every camera the machine has, for the picker.
    public let cameras: [VisionCamera]
    /// Source pixel dimensions and the last mirror flag; zeroed while closed.
    public let geometry: VisionFrameGeometry
    /// All five topics, sorted by name, running or not.
    public let topics: [VisionTopicReport]
    /// Models that currently exist. Should always equal the `model`-bearing
    /// running topics; reported separately because a divergence is exactly the
    /// leak (a model left constructed after its topic stopped) this readout
    /// should make visible rather than hide.
    public let activeModels: [String]
    /// Live requesters, sorted, including ones that have retracted to no
    /// topics — a connected consumer wanting nothing is a different and more
    /// useful statement than a consumer that is not there.
    public let requesters: [VisionRequesterState]
    public let warnings: [VisionWarning]
    public let counters: VisionCounters
    /// Whether a signals computer is wired in. `false` means
    /// `vision.signals.v1` is never published even when requested, which is a
    /// deployment fact a reader of this page needs rather than a silence to
    /// puzzle over.
    public let signalsAvailable: Bool

    public init(capturing: Bool,
                captureFPS: Int,
                permission: VisionPermission,
                device: VisionCamera?,
                cameras: [VisionCamera],
                geometry: VisionFrameGeometry,
                topics: [VisionTopicReport],
                activeModels: [String],
                requesters: [VisionRequesterState],
                warnings: [VisionWarning],
                counters: VisionCounters,
                signalsAvailable: Bool) {
        self.capturing = capturing
        self.captureFPS = captureFPS
        self.permission = permission
        self.device = device
        self.cameras = cameras
        self.geometry = geometry
        self.topics = topics
        self.activeModels = activeModels
        self.requesters = requesters
        self.warnings = warnings
        self.counters = counters
        self.signalsAvailable = signalsAvailable
    }

    /// Topics actually running, in the order the readout lists them.
    public var running: [VisionTopicReport] { topics.filter(\.running) }
}
