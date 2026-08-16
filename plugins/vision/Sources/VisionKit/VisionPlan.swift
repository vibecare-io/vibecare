import Foundation

/// What one topic will actually do, once intent and demand have been
/// intersected.
public struct VisionTopicPlan: Sendable, Equatable {
    /// The rate this topic publishes at — `max()` across its live requesters,
    /// capped at `RequestRegistry.maxFPS`. Independent of every other topic's
    /// rate: a 2 fps body-pose consumer and a 30 fps face consumer coexist,
    /// with body-pose inference running twice a second rather than thirty
    /// times.
    public let fps: Int
    /// The kernel's subscriber count for this topic — the liveness half.
    public let subscribers: Int
    /// Who asked for it, sorted. This is the privacy readout's whole point:
    /// one place that says "the camera is on because postures wants body
    /// pose".
    public let requesters: [String]
    /// Whether this topic's payload goes on the bus.
    ///
    /// `false` for a FEEDER: a model that runs only so that
    /// `vision.signals.v1` has landmarks to do arithmetic on, whose own topic
    /// nobody subscribes to. Publishing it would be a message core drops at
    /// zero demand anyway, so the flag saves a serialization per frame — but
    /// the reason it exists is honesty, not cost: `/api/state` shows a feeder
    /// as running with `subscribers: 0`, which is exactly what is true.
    public let publishes: Bool

    public init(fps: Int, subscribers: Int, requesters: [String], publishes: Bool = true) {
        self.fps = fps
        self.subscribers = subscribers
        self.requesters = requesters
        self.publishes = publishes
    }
}

/// A topic with subscribers but no live request naming it.
///
/// Demand governs whether the provider *may* run a model; the request union
/// governs whether it *does*. A consumer that declares
/// `subscribes: [vision.face.v1]` and never publishes a request sits there
/// receiving nothing at all, which is indistinguishable from a broken bus.
/// This is the single most likely way to wire a new consumer up wrong, so it
/// is logged on transition **and** surfaced in `/api/state` — it is not "just
/// logging", and dropping it from the readout removes the only signal a
/// misconfigured consumer ever produces.
public struct VisionWarning: Sendable, Equatable, Codable {
    /// Which way the wiring is wrong. Both shapes end in "a consumer is
    /// listening and receiving nothing", but they are fixed in opposite
    /// places, so they must not share one message.
    public enum Kind: String, Sendable, Equatable, Codable {
        /// Demand without a request: someone subscribed and never asked.
        case subscriberWithNoRequest
        /// A request naming only `vision.signals.v1`, which costs no
        /// inference. Nothing derives signals, so nothing is published — and
        /// the camera stays shut rather than running for a silent topic.
        case signalsWithoutAnyModel
    }

    public let topic: String
    public let subscribers: Int
    public let kind: Kind

    public init(topic: String, subscribers: Int, kind: Kind = .subscriberWithNoRequest) {
        self.topic = topic
        self.subscribers = subscribers
        self.kind = kind
    }

    /// The exact line the design specifies, so the log and the API readout
    /// cannot drift into two different wordings.
    public var message: String {
        switch kind {
        case .subscriberWithNoRequest:
            return "subscriber with no request topic=\(topic) subscribers=\(subscribers)"
        case .signalsWithoutAnyModel:
            return "request names only \(topic) topic=\(topic) subscribers=\(subscribers)"
                + " — signals costs no inference, so nothing derives it and the camera stays closed;"
                + " the requester must also name the model topics it wants run"
        }
    }
}

/// The intersection of intent and demand: everything the capture path needs to
/// know, computed as one immutable value so the frame path never re-derives it
/// and never disagrees with the readout.
public struct VisionPlan: Sendable, Equatable {
    public let topics: [VisionTopic: VisionTopicPlan]
    public let warnings: [VisionWarning]

    public init(topics: [VisionTopic: VisionTopicPlan], warnings: [VisionWarning]) {
        self.topics = topics
        self.warnings = warnings
    }

    /// Nothing running, nothing warned about.
    public static let idle = VisionPlan(topics: [:], warnings: [])

    /// The models that must exist for this plan, and no others. Constructed
    /// lazily when they enter this set, **released when they leave it** — an
    /// idle `VNRequest` still holds resources, so a topic whose demand or
    /// requests dropped to zero must not leave one parked.
    public var models: Set<VisionTopic> {
        Set(topics.keys.filter { $0.model != nil })
    }

    /// The rate the capture session runs at: `max()` of the per-topic rates,
    /// capped at 30. `0` means **stop the session** — the LED goes off.
    public var captureFPS: Int {
        min(RequestRegistry.maxFPS, topics.values.map(\.fps).max() ?? 0)
    }

    /// Whether the camera should be open at all.
    ///
    /// Keyed to `models`, **not** to `topics`. `vision.signals.v1` costs no
    /// inference, so a plan holding signals alone would open the camera and
    /// then publish nothing at all — every derived field absent, because no
    /// model ran to derive one from. `VisionPlanner.plan` drops that plan
    /// before it reaches here; this keeps the invariant true anyway, for any
    /// future topic whose `model` is `nil`.
    public var wantsCapture: Bool { !models.isEmpty }

    public func fps(_ topic: VisionTopic) -> Int? { topics[topic]?.fps }

    /// Topics in a stable order, for readouts and assertions.
    public var runningTopics: [VisionTopic] { topics.keys.sorted() }
}

/// Merges the two halves of the control plane into a `VisionPlan`.
///
/// A pure function of `(requests, demand, now)` with no state and no clock of
/// its own, which is what makes "a request for one topic constructs exactly
/// one model" and "all consumers disabled closes the session" assertable
/// without a camera, a kernel or a sleep.
///
/// The rule, in one line:
///
/// > a topic runs **iff** a live request names it **and** its kernel demand is
/// > non-zero.
///
/// Both conjuncts matter and they fail in opposite directions. Demand without
/// a request is a misconfigured consumer, and produces a warning. A request
/// without demand is a consumer that asked for work nobody will receive, and
/// produces nothing at all — the demand floor is not negotiable, so a stale
/// request from a dead consumer can never hold the camera open.
///
/// ## The one exception: feeder models
///
/// `vision.signals.v1` is not a model. It is arithmetic over landmarks, so
/// running it while no landmark model runs publishes a message with every
/// field absent — a working tier with nothing to say, which is the one reading
/// the contract forbids.
///
/// That is not hypothetical. The design's §5.5 writes blink-jump's manifest as
/// `subscribes: [vision.signals.v1]` and nothing else, and §4.4 promises it is
/// "~50 lines against `vision.signals.v1`" that never sees a landmark. Under
/// the bare conjunction that consumer gets an empty stream forever: it can
/// *request* `vision.face.v1`, but nothing subscribes to face, so demand is
/// structurally zero and the floor blocks the model it needs.
///
/// So: a model topic a live request names, whose requester **also** named
/// `vision.signals.v1`, runs as a FEEDER when signals itself is running — its
/// model is constructed and its output feeds the arithmetic, but nothing is
/// published on its topic.
///
/// This does not weaken the privacy floor, which is what the floor is for:
///
/// * a feeder cannot exist unless `vision.signals.v1` itself cleared the full
///   floor, i.e. a live process is genuinely subscribed and genuinely
///   receiving. The camera is never open for nobody.
/// * a feeder cannot by itself hold the camera open — kill the signals
///   subscriber and `topics[.signals]` goes, taking every feeder with it on
///   the same reconcile.
/// * a consumer still pays only for what it names. Naming `signals` alone
///   feeds nothing; the requester says which models it is asking to be run,
///   so the cost model stays truthful.
public enum VisionPlanner {
    public static func plan(requests: RequestRegistry,
                            demand: DemandTable,
                            at now: ContinuousClock.Instant) -> VisionPlan {
        let intent = requests.intent(at: now)
        var topics: [VisionTopic: VisionTopicPlan] = [:]
        var warnings: [VisionWarning] = []

        for topic in VisionTopic.allCases {
            let subscribers = demand.subscribers(topic)
            guard subscribers > 0 else {
                // The floor. Whatever anybody asked for, nobody is listening,
                // so nothing runs. Deliberately silent: zero demand is the
                // normal resting state of an idle machine, not a misconfig.
                continue
            }
            guard let want = intent[topic] else {
                warnings.append(VisionWarning(topic: topic.name, subscribers: subscribers))
                continue
            }
            topics[topic] = VisionTopicPlan(
                fps: min(RequestRegistry.maxFPS, max(1, want.fps)),
                subscribers: subscribers,
                requesters: want.requesters
            )
        }

        addFeeders(to: &topics, requests: requests, demand: demand, at: now)

        // Signals with nothing to derive from.
        //
        // A requester naming ONLY `vision.signals.v1` clears both halves of
        // the floor, so the bare rule admits it — and then `addFeeders` finds
        // no model topic it also asked for, no model runs, and
        // `FrameProcessor.publishSignalsIfDue` returns early on an empty
        // bundle. The camera would be open for a topic that can never say
        // anything, and the readout would report it as the reassuring "the
        // camera is on because X wants signals".
        //
        // Dropping the topic is what keeps `wantsCapture` honest. The warning
        // is the only thing in the system that can tell that consumer's author
        // what they forgot — that naming `signals` alone feeds nothing, and
        // the requester must also name the model topics it wants run.
        if topics[.signals] != nil, !topics.keys.contains(where: { $0.model != nil }) {
            topics[.signals] = nil
            warnings.append(VisionWarning(topic: VisionTopic.signals.name,
                                          subscribers: demand.subscribers(.signals),
                                          kind: .signalsWithoutAnyModel))
        }

        return VisionPlan(topics: topics, warnings: warnings.sorted { $0.topic < $1.topic })
    }

    /// Adds the models `vision.signals.v1` needs but nobody subscribes to.
    /// See the type's doc comment for why this exists and why it is safe.
    private static func addFeeders(to topics: inout [VisionTopic: VisionTopicPlan],
                                   requests: RequestRegistry,
                                   demand: DemandTable,
                                   at now: ContinuousClock.Instant) {
        // Nothing to feed. This guard is the whole safety argument: no feeder
        // exists unless signals cleared the full demand-and-request floor.
        guard topics[.signals] != nil else { return }

        let signalsRequesters = requests.live(at: now).filter { $0.topics.contains(.signals) }
        guard !signalsRequesters.isEmpty else { return }

        for topic in VisionModelTopics.sorted() where topics[topic] == nil {
            let asked = signalsRequesters.filter { $0.topics.contains(topic) }
            guard !asked.isEmpty else { continue }
            topics[topic] = VisionTopicPlan(
                // Same max()-across-requesters rule as any other topic. A
                // feeder that ran slower than the signals topic it feeds would
                // make every derived field stale rather than absent, which is
                // the harder failure to see.
                fps: min(RequestRegistry.maxFPS, max(1, asked.map(\.fps).max() ?? RequestRegistry.defaultFPS)),
                // Genuinely zero, and reported as zero: nobody is subscribed
                // to this topic. The readout says "running, 0 subscribers,
                // asked for by blink-jump", which is the truth.
                subscribers: demand.subscribers(topic),
                requesters: asked.map(\.requester).sorted(),
                publishes: false
            )
        }
    }
}
