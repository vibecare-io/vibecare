import Foundation
import VCKStubs
import VCPluginSDK

/// The composition point: bus events in, nudges out.
///
/// Everything with a decision in it lives elsewhere and is unit-tested there
/// — `PostureScore` decides what a frame means, `PosturePolicy` decides when
/// a run of frames has earned a nudge, `VisionRequester` decides what to ask
/// vision for. This actor owns the wiring, the caches `/api/state` reads, and
/// the one piece of judgement that needs a wall clock: what to do about a gap
/// in the stream.
public actor PostureMonitor {
    /// A gap longer than this breaks continuity outright.
    ///
    /// `PosturePolicy.unknownGrace` covers frames that arrive and say
    /// nothing; this covers frames that do not arrive at all — the laptop
    /// slept, vision crashed, core restarted. Without it, waking after two
    /// hours would hand the policy a `poorSince` two hours old and fire a
    /// nudge on the very first frame, describing a slouch that happened while
    /// the lid was shut.
    ///
    /// 15 s is 30 missed frames at the 2 fps this plugin requests, and half
    /// the request TTL — comfortably longer than any hiccup that is not a
    /// real outage.
    static let maxFrameGap: TimeInterval = 15

    private let config: ConfigStore
    private let counts: NudgeCountsStore
    private let snooze: SnoozeGate
    private let requester: VisionRequester
    private let now: @Sendable () -> Date

    private var host: (any PostureHost)?
    private var cached: PostureConfig
    private var policy: PosturePolicy
    private var tracker = PostureTracker()

    // Observability. None of it is load-bearing for a nudge; all of it is
    // what makes `/api/state` an honest readout rather than a decoration.
    private var lastSample: PostureSample?
    private var lastVerdict: PostureVerdict = .unknown
    private var lastFrameAt: Date?
    private var lastIngestTime: TimeInterval?
    private var bodyPoseFrames = 0
    private var signalsFrames = 0
    private var signalsWithShoulderAngle = 0
    private var signalsWithNeckForward = 0
    private var demand: [String: Int] = [:]
    private var lastNudgeAt: Date?
    private var lastAlertError: String?
    private var todayCount = 0
    private var todayKey = ""

    public init(
        config: ConfigStore,
        counts: NudgeCountsStore,
        snooze: SnoozeGate,
        requester: VisionRequester,
        initial: PostureConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.counts = counts
        self.snooze = snooze
        self.requester = requester
        self.now = now
        self.cached = initial
        self.policy = PosturePolicy(dwell: initial.dwell, cooldown: initial.cooldown)
    }

    public func attach(host: any PostureHost) async {
        self.host = host
        await requester.attach(host: host)
    }

    // MARK: - Lifecycle

    /// Loads persisted state, asserts the vision request, starts the
    /// heartbeat, and consumes the event stream until it finishes.
    ///
    /// Never returns under normal operation — `VCHost.events()` finishes only
    /// on shutdown — so the composition root runs it in a detached `Task` and
    /// parks in `waitForShutdown()`.
    public func start(events: AsyncStream<VCEvent>) async {
        cached = await config.load()
        policy = PosturePolicy(dwell: cached.dwell, cooldown: cached.cooldown)
        await refreshTodayCount()
        await requester.setEnabled(cached.enabled)
        await requester.startHeartbeat()
        await consume(events)
    }

    public func stop() async {
        await requester.stop()
        host = nil
    }

    /// Split out from `start` so a test can drive a stream it controls
    /// without also exercising the persisted-state load.
    public func consume(_ events: AsyncStream<VCEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    // MARK: - Event routing

    func handle(_ event: VCEvent) async {
        switch event.topic {
        case VCTopicDemand:
            // Authoritative STATE, not a delta — overwrite, never accumulate.
            // A full burst arrives on every reconnect, which is the only
            // signal a plugin gets that its Register stream came back, so it
            // is also where the request gets re-asserted. See
            // `VisionRequester`'s doc comment.
            if let d = try? JSONDecoder().decode(VCDemand.self, from: event.payload) {
                demand[d.topic] = d.subscribers
            }
            await requester.reassert()

        case VisionRequest.bodyPoseTopic:
            guard let frame = try? VCTBodyPoseFrame(serializedBytes: event.payload) else {
                posturesLog("undecodable \(event.topic) payload (\(event.payload.count) bytes); dropped")
                return
            }
            bodyPoseFrames += 1
            await evaluate(tracker.ingest(bodyPose: BodyPoseReading(frame)))

        case VisionRequest.signalsTopic:
            guard let signals = try? VCTSignals(serializedBytes: event.payload) else {
                posturesLog("undecodable \(event.topic) payload (\(event.payload.count) bytes); dropped")
                return
            }
            signalsFrames += 1
            if signals.hasShoulderAngle { signalsWithShoulderAngle += 1 }
            if signals.hasNeckForward { signalsWithNeckForward += 1 }
            await evaluate(tracker.ingest(signals: PostureSample.from(signals: signals)))

        default:
            // Core only delivers what the manifest subscribes to plus the
            // reserved demand topic, so this is unreachable short of a
            // manifest change that landed without matching code.
            posturesLog("ignoring unexpected topic \(event.topic)")
        }
    }

    // MARK: - Evaluation

    private func evaluate(_ sample: PostureSample) async {
        let at = now()
        let t = at.timeIntervalSince1970

        // Continuity check before anything else — see `maxFrameGap`.
        if let last = lastIngestTime, t - last > Self.maxFrameGap || t < last {
            policy.reset()
        }
        lastIngestTime = t
        lastFrameAt = at
        lastSample = sample

        let verdict = PostureScore.verdict(for: sample, config: cached)
        lastVerdict = verdict

        // The readout above is updated even while disabled: another consumer
        // may still be driving vision, and showing the user what their
        // posture actually looks like is exactly how they decide whether to
        // switch this on. What being disabled costs is the nudge, and the
        // accumulated run behind it.
        guard cached.enabled else {
            policy.reset()
            return
        }
        guard let nudge = policy.ingest(verdict, at: t) else { return }
        await fire(nudge, at: at)
    }

    private func fire(_ nudge: PostureNudge, at date: Date) async {
        // Snooze first, and it suppresses the COUNT as well as the alert.
        // "Nudges today" has to mean nudges the user actually received, or
        // the number in the UI and the ordinal in the alert copy are both
        // lies. The policy has already recorded the fire, so the cooldown
        // runs from here regardless — a snooze that ends mid-cooldown does
        // not release a backlog.
        guard !(await snooze.isActive(now: date)) else {
            posturesLog("nudge suppressed by an active snooze")
            return
        }
        guard let host else {
            posturesLog("nudge earned before a host was attached; dropped")
            return
        }

        await refreshTodayCount(at: date)
        let count: Int
        do {
            count = try await counts.increment(on: todayKey)
        } catch {
            // A failed write must not cost the user the nudge. Carry on with
            // the in-memory number, which is right for this session even if
            // it will not survive a restart.
            posturesLog("counts write failed: \(error)")
            count = todayCount + 1
        }
        todayCount = count
        lastNudgeAt = date

        let alert = VCAlert(
            title: NudgeCopy.title,
            body: NudgeCopy.body(faults: nudge.faults, sustained: nudge.sustained, count: count),
            level: "warn",
            actions: [
                // Both endpoints accept GET as well as POST: a client
                // following an action URL issues a GET, and core's proxy does
                // not rewrite methods.
                VCAlertAction(label: "Snooze 30 min", url: "api/snooze?minutes=30"),
                VCAlertAction(label: "Turn off", url: "api/config/disable"),
            ],
            appearance: Self.appearance
        )
        do {
            try await host.alert(alert)
            lastAlertError = nil
        } catch {
            // Core may be mid-reconnect. A dropped alert is not a reason to
            // crash the plugin, and the cooldown means the next one is
            // fifteen minutes away regardless.
            lastAlertError = "\(error)"
            posturesLog("alert failed: \(error)")
        }

        // Nothing is published to the bus here on purpose. The manifest
        // declares exactly one publish topic, `vision.request.v1`; a
        // `postures.*` topic that is not in `publishes` would be a logged
        // error and a dropped message, and adding one needs a manifest change
        // and a core restart, not a line here.
    }

    /// Sent on EVERY nudge, not only customized ones, so the out-of-the-box
    /// alert is the good-looking one rather than a hidden setting.
    ///
    /// `svgPath` is plugin-RELATIVE. A plugin cannot know the port core
    /// assigned it, so a relative path is the only icon reference it can
    /// honestly send; the client resolves it against `/p/postures/` and
    /// fetches it back through the proxy. `API.swift` serves it from
    /// `/icons/`.
    ///
    /// No screen blur: this is a two-minute posture nudge, not an
    /// interruption worth dimming the user's work for. `level: "warn"` above
    /// already buys the longer banner.
    static let appearance = VCAlertAppearance(
        svgPath: "icons/posture.svg",
        svgWidth: 220,
        svgHeight: 150,
        position: .topRight,
        width: 420,
        height: 210,
        moveable: true,
        autoDismissAfter: 20,
        screenBlurEnabled: false
    )

    // MARK: - Config

    /// Applies a config that has ALREADY been persisted, so the in-memory
    /// state can never diverge from what is on disk. Callers pass
    /// `config.load()`, not the raw decode of a request body.
    public func apply(_ c: PostureConfig) async {
        cached = c
        policy.dwell = c.dwell
        policy.cooldown = c.cooldown
        // Thresholds may have moved, so the run accumulated under the old
        // ones is no longer evidence for anything. `reset()` keeps
        // `lastFired`, so this is not a way to bypass the cooldown.
        policy.reset()
        await requester.setEnabled(c.enabled)
    }

    // MARK: - Readout

    private func refreshTodayCount(at date: Date? = nil) async {
        let key = NudgeCountsStore.dayKey(date ?? now())
        guard key != todayKey else { return }
        todayKey = key
        todayCount = await counts.count(on: key)
    }

    public func snapshot() async -> PostureStateDTO {
        let at = now()
        await refreshTodayCount(at: at)
        let t = at.timeIntervalSince1970

        return PostureStateDTO(
            enabled: cached.enabled,
            config: cached,
            request: RequestStateDTO(
                topics: await requester.lastAssertedTopics,
                fps: VisionRequest.fps,
                ttlSeconds: VisionRequest.ttlSeconds,
                heartbeatSeconds: VisionRequest.heartbeat,
                lastAssertedAt: await requester.lastAssertedAt,
                assertCount: await requester.assertCount,
                lastError: await requester.lastError,
                subscribers: demand
            ),
            reading: lastSample.map {
                ReadingDTO(seq: $0.seq,
                           shoulderAngle: $0.shoulderAngle,
                           neckForward: $0.neckForward,
                           bodyDetected: $0.bodyDetected,
                           at: lastFrameAt)
            },
            verdict: lastVerdict.name,
            faults: lastVerdict.faults.names,
            poorForSeconds: policy.poorFor(at: t),
            nudgesToday: todayCount,
            day: todayKey,
            lastNudgeAt: lastNudgeAt,
            lastAlertError: lastAlertError,
            snoozedUntil: await snooze.deadline(),
            frames: FrameCountsDTO(bodyPose: bodyPoseFrames,
                                   signals: signalsFrames,
                                   signalsWithShoulderAngle: signalsWithShoulderAngle,
                                   signalsWithNeckForward: signalsWithNeckForward),
            notes: notes(at: at)
        )
    }

    /// Plain-language warnings for the states that are otherwise
    /// indistinguishable from "working, nothing to report".
    ///
    /// This is spec §5.3's loudness requirement taken seriously: a consumer
    /// that is subscribed but receiving nothing looks exactly like a consumer
    /// whose user simply has good posture, and the only thing that can tell
    /// them apart is a readout that says so.
    func notes(at date: Date) -> [String] {
        var out: [String] = []

        if !cached.enabled {
            out.append("Postures is off. The vision request is retracted, so vision is not running a body-pose model for this plugin.")
            return out
        }
        if bodyPoseFrames == 0 && signalsFrames == 0 {
            out.append("No vision frames received yet. Check that the vision plugin is installed and running — postures never opens a camera itself.")
        } else if let last = lastFrameAt, date.timeIntervalSince(last) > Self.maxFrameGap {
            out.append("No vision frames for \(NudgeCopy.duration(date.timeIntervalSince(last))). The dwell timer has been reset.")
        }
        if signalsFrames > 0 && signalsWithShoulderAngle == 0 && signalsWithNeckForward == 0 {
            out.append("Signals frames are arriving but carry neither shoulder_angle nor neck_forward. Absent is not zero, so posture is reported as unknown rather than good.")
        }
        if let subscribers = demand[VisionRequest.topic], subscribers == 0 {
            out.append("Nothing is subscribed to \(VisionRequest.topic). The request is being published into the void — is the vision plugin running?")
        }
        return out
    }
}

// MARK: - `/api/state` wire shapes

public struct FrameCountsDTO: Encodable, Sendable {
    public var bodyPose: Int
    public var signals: Int
    public var signalsWithShoulderAngle: Int
    public var signalsWithNeckForward: Int
}

public struct RequestStateDTO: Encodable, Sendable {
    public var topics: [String]
    public var fps: UInt32
    public var ttlSeconds: UInt32
    public var heartbeatSeconds: TimeInterval
    public var lastAssertedAt: Date?
    public var assertCount: Int
    public var lastError: String?
    /// Subscriber counts from `_core.demand.v1`, keyed by topic. Only ever
    /// contains topics this plugin publishes — core announces demand to
    /// publishers, not to subscribers.
    public var subscribers: [String: Int]
}

/// The latest measurement. Every field is `Optional` all the way to the wire
/// — the synthesized encoding omits the key entirely when a measurement is
/// absent, so there is deliberately no way for this to emit a `0` that means
/// "not measured". `index.html` tests for the key's presence, never for a
/// falsy value.
public struct ReadingDTO: Encodable, Sendable {
    public var seq: UInt64
    public var shoulderAngle: Double?
    public var neckForward: Double?
    public var bodyDetected: Bool?
    public var at: Date?
}

public struct PostureStateDTO: Encodable, Sendable {
    public var enabled: Bool
    public var config: PostureConfig
    public var request: RequestStateDTO
    public var reading: ReadingDTO?
    public var verdict: String
    public var faults: [String]
    public var poorForSeconds: TimeInterval?
    public var nudgesToday: Int
    public var day: String
    public var lastNudgeAt: Date?
    public var lastAlertError: String?
    public var snoozedUntil: Date?
    public var frames: FrameCountsDTO
    public var notes: [String]
}
