import Foundation
import VCKStubs

/// One consumer's live desired state, parsed from a `vision.request.v1`
/// message with every default already resolved.
public struct VisionRequest: Sendable, Equatable {
    /// The requesting plugin's id, **self-asserted and not authenticated**.
    /// `BusEvent` carries `{Topic, Payload, TS}` and no publisher identity,
    /// and `Event` in `plugin.proto` has no source field either, so this is
    /// what the requester claims to be and nothing more. Acceptable because
    /// the channel cannot grant capability — it can only ask for work the
    /// demand floor still gates — but it is a real limitation, recorded here
    /// rather than discovered later.
    public let requester: String

    /// Desired topics, with unknown names already dropped. **Empty is
    /// meaningful**: it retracts this requester's intent entirely, which is
    /// how a detector switched off in its own UI stops the models it was
    /// driving without exiting its process.
    public let topics: Set<VisionTopic>

    /// Desired frame rate, already defaulted (0/absent -> 15) and capped at
    /// 30. Per topic the provider runs `max()` across live requesters.
    public let fps: Int

    /// How long this request stays live without re-assertion, already
    /// defaulted (0 -> 30s).
    public let ttl: Duration

    /// When the request arrived, on the **monotonic** clock. See
    /// `visionSeconds` for why nothing here uses `Date`.
    public let receivedAt: ContinuousClock.Instant

    public init(requester: String,
                topics: Set<VisionTopic>,
                fps: Int,
                ttl: Duration,
                receivedAt: ContinuousClock.Instant) {
        self.requester = requester
        self.topics = topics
        self.fps = fps
        self.ttl = ttl
        self.receivedAt = receivedAt
    }

    public var expiresAt: ContinuousClock.Instant { receivedAt + ttl }

    public func isLive(at now: ContinuousClock.Instant) -> Bool { now < expiresAt }

    /// Seconds until this request expires; never negative.
    public func remainingSeconds(at now: ContinuousClock.Instant) -> TimeInterval {
        max(0, visionSeconds(expiresAt - now))
    }

    /// Topic names in a stable order, for readouts and assertions.
    public var topicNames: [String] { topics.sorted().map(\.name) }

    /// Equality that deliberately ignores `receivedAt`, so a heartbeat
    /// re-asserting the identical desired state is recognised as "unchanged"
    /// and does not produce a log line every 10 seconds.
    func statesEqual(_ other: VisionRequest) -> Bool {
        requester == other.requester && topics == other.topics
            && fps == other.fps && ttl == other.ttl
    }
}

/// What every live requester, taken together, wants for one topic.
public struct VisionTopicIntent: Sendable, Equatable {
    /// `max()` of the live requesters' rates. Per-topic and independent: a
    /// 2 fps posture consumer must not drag body-pose inference to 30 because
    /// a game wants faces fast.
    public let fps: Int
    /// Who asked, sorted, for the privacy readout.
    public let requesters: [String]
}

/// The intent half of the control plane: desired state published by consumers
/// on `vision.request.v1`, **latest-wins per requester**, expiring by TTL.
///
/// This is a value type with no clock of its own — every method takes `now`.
/// That is what makes TTL expiry, latest-wins and the union assertable in a
/// unit test without sleeping, and it is why the actor that owns one passes
/// `ContinuousClock.now` in rather than the registry reading it.
///
/// The registry is truthful about **intent** only. It never decides whether a
/// model runs; `VisionPlanner` gates it against the demand refcount, which is
/// the half that is truthful about **liveness**.
public struct RequestRegistry: Sendable, Equatable {
    /// `fps` of 0 or absent means this.
    public static let defaultFPS = 15
    /// `ttl_s` of 0 or absent means this.
    public static let defaultTTL: Duration = .seconds(30)
    /// The capture session is capped here, so no single topic can ask for
    /// more either.
    public static let maxFPS = 30

    private var entries: [String: VisionRequest] = [:]

    public init() {}

    /// Applies a decoded `vision.request.v1` message.
    ///
    /// Returns `true` when the message was accepted (whether or not it changed
    /// anything) and `false` when it was rejected outright. The only rejection
    /// is an empty `requester`: the field is how latest-wins identifies the
    /// publisher, so an empty one would make every anonymous consumer
    /// overwrite every other anonymous consumer's request. That is loud rather
    /// than silent for the same reason §5.3's warning is.
    @discardableResult
    public mutating func apply(_ message: VCTRequest, at now: ContinuousClock.Instant) -> Bool {
        let requester = message.requester.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requester.isEmpty else {
            visionLog("vision.request.v1 with an empty requester; ignoring it — "
                      + "the field is how latest-wins tells consumers apart")
            return false
        }

        var topics: Set<VisionTopic> = []
        var unknown: [String] = []
        for name in message.topics {
            if let topic = VisionTopic(rawValue: name) {
                topics.insert(topic)
            } else {
                unknown.append(name)
            }
        }

        let request = VisionRequest(
            requester: requester,
            topics: topics,
            fps: message.fps == 0 ? Self.defaultFPS : min(Int(message.fps), Self.maxFPS),
            ttl: message.ttlS == 0 ? Self.defaultTTL : .seconds(Int(message.ttlS)),
            receivedAt: now
        )

        // Log only on a CHANGE. A consumer re-asserts on a heartbeat well
        // inside the TTL (10 s against 30 s), so logging every message would
        // bury the interesting lines under a steady drip of identical ones.
        let previous = entries[requester]
        if previous == nil || !(previous!.statesEqual(request)) {
            let topicList = request.topicNames.joined(separator: ",")
            visionLog("request requester=\(requester) topics=[\(topicList)] "
                      + "fps=\(request.fps) ttl=\(visionSeconds(request.ttl))s")
            if !unknown.isEmpty {
                visionLog("request requester=\(requester) named unknown topics "
                          + "[\(unknown.joined(separator: ","))]; ignoring them")
            }
        }

        // Latest-wins, unconditionally — including a request whose `topics` is
        // empty, which is stored rather than deleted so the readout can say
        // "vibecheck is connected and wants nothing" instead of the strictly
        // less informative "vibecheck is not here".
        entries[requester] = request
        return true
    }

    /// Test/composition-root entry point for a pre-built request, skipping the
    /// wire type.
    public mutating func apply(_ request: VisionRequest) {
        entries[request.requester] = request
    }

    /// Drops every request past its TTL and returns the requester ids dropped,
    /// sorted, so the caller can log them. A wedged consumer that stops
    /// heartbeating loses its intent here; one that dies outright is handled
    /// sooner and more bluntly by the demand floor.
    @discardableResult
    public mutating func expire(at now: ContinuousClock.Instant) -> [String] {
        let dead = entries.filter { !$0.value.isLive(at: now) }.keys.sorted()
        for id in dead { entries.removeValue(forKey: id) }
        return dead
    }

    /// Live requests, sorted by requester.
    public func live(at now: ContinuousClock.Instant) -> [VisionRequest] {
        entries.values.filter { $0.isLive(at: now) }.sorted { $0.requester < $1.requester }
    }

    /// The union across live requesters: for each topic somebody asked for,
    /// the `max()` rate and who asked.
    ///
    /// A topic nobody asked for is **absent from the result**, which is a
    /// different statement from "present at 0 fps" — the planner reads absence
    /// as "do not construct this model at all".
    public func intent(at now: ContinuousClock.Instant) -> [VisionTopic: VisionTopicIntent] {
        var fps: [VisionTopic: Int] = [:]
        var requesters: [VisionTopic: [String]] = [:]
        // `live(at:)` is already sorted by requester, so `requesters` comes out
        // sorted without a second pass.
        for request in live(at: now) {
            for topic in request.topics {
                fps[topic] = max(fps[topic] ?? 0, request.fps)
                requesters[topic, default: []].append(request.requester)
            }
        }
        return fps.reduce(into: [:]) { out, entry in
            out[entry.key] = VisionTopicIntent(fps: entry.value,
                                               requesters: requesters[entry.key] ?? [])
        }
    }

    /// Whether any requester at all is live. Distinct from "the union is
    /// non-empty": a requester that has retracted to `topics: []` is still
    /// live and still heartbeating.
    public func isEmpty(at now: ContinuousClock.Instant) -> Bool {
        live(at: now).isEmpty
    }
}
