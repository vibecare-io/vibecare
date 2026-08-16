import Foundation

/// The one thing this plugin needs from `VCHost`, narrowed to a protocol so
/// the request lifecycle is testable without a unix socket and a live kernel.
public protocol BusPublisher: Sendable {
    func publish(topic: String, payload: Data) async throws
}

/// Owns `vision.request.v1` for this plugin.
///
/// The demand story, stated once: the kernel's refcount is truthful about
/// LIVENESS (zero subscribers closes the camera, always — the privacy floor)
/// but cannot know INTENT. This process stays up and stays subscribed to
/// `vision.signals.v1` for as long as core runs, so demand alone would hold
/// the camera open with the LED on while nobody is playing. The request topic
/// is what closes that gap: **the game being closed publishes `topics: []`,
/// and the camera goes off.**
///
/// Three things re-assert, and all three are needed:
///
/// 1. a change of intent — the first player attaches, or the last one leaves;
/// 2. a 10 s heartbeat, against the 30 s TTL, because events are ephemeral and
///    a request published while the provider was restarting is simply gone;
/// 3. every `_core.demand.v1` event. Core announces demand for a plugin's own
///    published topics on *every* `Subscribe`, so a demand event is precisely
///    a "your Register stream just (re)connected" signal — which is the
///    reconnect re-assertion the design asks for, with nothing added to the
///    SDK to detect it.
public actor VisionRequester {
    /// Well inside the TTL, so one lost heartbeat is not a dropped camera.
    public static let heartbeat: Duration = .seconds(10)
    public static let ttlSeconds: UInt32 = 30

    /// What `/api/state` reports about the control plane. This readout is not
    /// decoration: a consumer that subscribes but never requests receives no
    /// events at all, which is indistinguishable from a broken bus, and this
    /// is where that is visible.
    public struct Snapshot: Sendable, Codable, Equatable {
        public var players: Int
        public var topics: [String]
        public var fps: Int
        public var ttlSeconds: Int
        public var assertions: Int
        public var lastAssertedAt: Date?
        public var lastError: String?
        /// Subscribers to `vision.request.v1`, straight from the kernel. Zero
        /// means nothing is listening for our request — i.e. the vision
        /// plugin is not running, and no amount of asking will start a camera.
        public var providerSubscribers: Int
        /// Whether a `VCHost` has been handed over yet. NOT "the gRPC dial
        /// succeeded" — the SDK reconnects underneath us forever and does not
        /// report that upwards, so the honest signal for a wedged connection
        /// is `lastError`, not this.
        public var hostAttached: Bool
    }

    private let requester: String
    private var publisher: (any BusPublisher)?

    private var players = 0
    private var fps: UInt32
    private var providerSubscribers = 0

    private var assertions = 0
    private var lastAssertedAt: Date?
    private var lastError: String?
    public private(set) var lastIntent: VisionRequestIntent?

    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    public init(requester: String, fps: Int = 30) {
        self.requester = requester
        self.fps = UInt32(min(30, max(5, fps)))
    }

    // MARK: - Intent

    /// What a live game asks the provider to run.
    ///
    /// Two entries, and this plugin only ever *reads* the first.
    /// `vision.signals.v1` is the topic it subscribes to and the only one it
    /// decodes; `vision.face.v1` is named because signals are arithmetic, not
    /// a model — asking for the arithmetic without asking for the eyes it is
    /// computed from yields a message with `ear_l` absent on every frame,
    /// forever, which is indistinguishable here from an eye that never opens.
    ///
    /// The provider runs face as a FEEDER for this: the model is constructed,
    /// its output feeds the signals math, and nothing is published on
    /// `vision.face.v1` because nothing subscribes to it (see
    /// `VisionPlanner.addFeeders` in plugins/vision). So this stays true to
    /// the design's §4.4 — blink-jump never sees a landmark — while being
    /// honest about the model it is asking somebody else to pay for.
    static let playingTopics = [VisionTopic.signals, VisionTopic.face]

    /// The request this plugin wants live *right now*.
    ///
    /// `topics: []` when nobody is playing. Not "publish nothing" — an empty
    /// list is a meaningful, latest-wins retraction, and staying silent
    /// instead would leave the previous request live until its TTL expired.
    public var intent: VisionRequestIntent {
        VisionRequestIntent(
            requester: requester,
            topics: players > 0 ? Self.playingTopics : [],
            fps: fps,
            ttlSeconds: Self.ttlSeconds
        )
    }

    /// Called by the engine whenever an SSE client attaches or detaches. Only
    /// a *change* publishes, so a page that opens two streams does not spam
    /// the bus — but the crossing of zero in either direction always does.
    public func setPlayers(_ count: Int) async {
        let previous = players
        players = max(0, count)
        guard (previous > 0) != (players > 0) else { return }
        await assertNow(reason: players > 0 ? "player attached" : "last player left")
    }

    public func setFPS(_ value: Int) async {
        let next = UInt32(min(30, max(5, value)))
        guard next != fps else { return }
        fps = next
        // Only worth a publish while someone is playing: the retracted request
        // carries an fps the provider has no use for.
        if players > 0 { await assertNow(reason: "fps changed") }
    }

    // MARK: - Wiring

    /// Attaches the live host and starts the heartbeat. Called immediately
    /// after `VCHost.connect()` returns, since no host exists before that.
    public func attach(publisher: any BusPublisher) async {
        self.publisher = publisher
        await assertNow(reason: "connected")
        startHeartbeat()
    }

    /// Feeds a `_core.demand.v1` event. Ignores every topic but our own
    /// published one — a plugin only ever receives demand for topics it
    /// publishes, but being explicit costs nothing and documents the fact.
    public func noteDemand(_ demand: VCDemandReading) async {
        guard demand.topic == VisionTopic.request else { return }
        providerSubscribers = demand.subscribers
        // Demand is announced on every Subscribe, so arriving here means our
        // Register stream is (re)established — re-assert, because the provider
        // may have restarted and forgotten us, and there is no replay.
        await assertNow(reason: "demand announced")
    }

    /// Publishes the retraction on the way down. Redundant by design — losing
    /// this process drops our subscription, demand for `vision.signals.v1`
    /// hits zero, and the provider closes the model regardless of any stale
    /// request — but it makes the shutdown path say out loud what it means,
    /// and it costs one small message inside the shutdown grace.
    public func stop() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        players = 0
        await assertNow(reason: "shutting down")
        stopped = true
        publisher = nil
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            players: players,
            topics: intent.topics,
            fps: Int(fps),
            ttlSeconds: Int(Self.ttlSeconds),
            assertions: assertions,
            lastAssertedAt: lastAssertedAt,
            lastError: lastError,
            providerSubscribers: providerSubscribers,
            hostAttached: publisher != nil
        )
    }

    // MARK: - Publishing

    /// Publishes the current intent. Never throws out to the caller: a failed
    /// publish is recorded and retried by the next heartbeat, because the
    /// alternative — surfacing it — has no correct handler anywhere up the
    /// stack, and certainly not one that should end the process.
    @discardableResult
    public func assertNow(reason: String) async -> Bool {
        guard !stopped, let publisher else { return false }
        let intent = self.intent
        do {
            try await publisher.publish(topic: VisionTopic.request, payload: intent.encoded())
            assertions += 1
            lastAssertedAt = Date()
            lastError = nil
            lastIntent = intent
            return true
        } catch {
            lastError = "\(reason): \(error)"
            return false
        }
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VisionRequester.heartbeat)
                guard !Task.isCancelled, let self else { return }
                // Re-asserted whether or not anyone is playing. Re-asserting
                // the *retraction* looks redundant against a TTL that would
                // expire it anyway, and it is — but it is one ~40 byte message
                // every ten seconds, and it means the provider's view of this
                // requester is refreshed from a single code path instead of
                // two that can disagree.
                await self.assertNow(reason: "heartbeat")
            }
        }
    }
}

/// `_core.demand.v1`'s JSON body, decoded.
///
/// A local mirror of the SDK's `VCDemand` rather than a re-export: the field
/// names are core's wire contract (`{"topic":…,"subscribers":…}`), and this
/// plugin's tests should be able to pin them without linking the SDK.
public struct VCDemandReading: Sendable, Codable, Equatable {
    public let topic: String
    public let subscribers: Int

    public init(topic: String, subscribers: Int) {
        self.topic = topic
        self.subscribers = subscribers
    }

    public static func decode(_ payload: Data) -> VCDemandReading? {
        try? JSONDecoder().decode(VCDemandReading.self, from: payload)
    }
}
