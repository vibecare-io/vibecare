import Foundation

/// One frame of detector state, for the page's calibration meter.
///
/// The meter is not decoration either. A player whose eyes are simply the
/// wrong shape for the shipped threshold gets a game that never jumps, and
/// without a live EAR readout there is nothing to distinguish that from "the
/// camera is off" or "the plugin is broken". Seeing the bar move while the
/// marker sits in the wrong place is the whole diagnosis.
public struct MeterUpdate: Codable, Sendable, Equatable {
    /// The fused reading the detector actually used. `null` means ABSENT —
    /// no measurement — and the page must render that as "looking for you",
    /// never as a shut eye.
    public var ear: Double?
    public var earL: Double?
    public var earR: Double?
    public var phase: String
    public var tracking: Bool
    /// The live band, echoed so the page can draw the two markers without
    /// having to re-fetch `/api/config` after every calibration.
    public var closeThreshold: Double
    public var openThreshold: Double
    public var blinks: Int
    public var seq: UInt64
}

/// A scored blink, on its way to the page as a jump.
public struct BlinkUpdate: Codable, Sendable, Equatable {
    public var index: Int
    public var closureMs: Int
    public var ear: Double
}

public enum GameEvent: Sendable {
    case meter(MeterUpdate)
    case blink(BlinkUpdate)
}

/// Turns `vision.signals.v1` into jumps, and the presence of a player into a
/// camera request.
///
/// Everything above this line is measurement (vision's job) and everything
/// below it is the game (the page's job); this actor is the one place that
/// holds a judgement, and the judgement is `BlinkDetector`'s.
public actor BlinkEngine {
    /// How often the detector is asked whether the signal has gone quiet.
    /// Well under the default 0.8 s `signalTimeout`, so the pause reaches the
    /// page within about a quarter second of the provider stopping.
    private static let watchdogInterval: Duration = .milliseconds(200)
    /// Meter updates are throttled; blinks never are. At 30 fps an unthrottled
    /// meter is 30 JSON messages a second through the kernel proxy for a bar
    /// that no eye can read faster than about 20 Hz anyway.
    private static let meterInterval: TimeInterval = 0.05

    private var detector: BlinkDetector
    private let requester: VisionRequester
    private let epoch = ContinuousClock.now

    private var listeners: [UUID: AsyncStream<GameEvent>.Continuation] = [:]
    private var watchdog: Task<Void, Never>?
    private var stopped = false

    private var lastMeterAt: TimeInterval = -.infinity
    private var lastPhase: BlinkPhase = .absent
    /// The per-eye readings behind `detector.reading`, kept for the meter so a
    /// player can see one eye tracking and the other not — which is what a bad
    /// camera angle looks like, and is invisible in the fused number.
    private var lastEarL: Double?
    private var lastEarR: Double?

    private var signalsReceived = 0
    private var lastSignalAt: Date?
    private var lastSeq: UInt64 = 0
    /// Gaps in `Header.seq`. A provider that is dropping frames because a
    /// subscriber is slow shows up here and nowhere else.
    private var droppedFrames: UInt64 = 0
    private var undecodableSignals = 0

    public init(thresholds: BlinkThresholds, requester: VisionRequester) {
        self.detector = BlinkDetector(thresholds: thresholds)
        self.requester = requester
    }

    // MARK: - Lifecycle

    public func start() {
        guard watchdog == nil, !stopped else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: BlinkEngine.watchdogInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    public func stop() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        for continuation in listeners.values { continuation.finish() }
        listeners.removeAll()
    }

    // MARK: - Players

    /// Registers one SSE client. The returned stream finishes when the client
    /// is detached or the engine stops, which is what lets the HTTP handler
    /// treat "the stream ended" as "this request is over".
    ///
    /// A player attaching is what turns the camera ON, via the requester — so
    /// this is the demand story's near end, and `detach` is its far end.
    public func attach() async -> (id: UUID, events: AsyncStream<GameEvent>) {
        let (stream, continuation) = AsyncStream<GameEvent>.makeStream(
            of: GameEvent.self,
            // Bounded and newest-wins: a browser tab that stops reading must
            // not grow this process's memory. Losing an old meter frame is
            // free; the buffer is deep enough that a blink behind a stall
            // still arrives.
            bufferingPolicy: .bufferingNewest(64)
        )
        guard !stopped else {
            continuation.finish()
            return (UUID(), stream)
        }
        let id = UUID()
        listeners[id] = continuation
        // Paint immediately rather than making the page wait for the first
        // frame from a camera that may take a second to open.
        continuation.yield(.meter(currentMeter()))
        await requester.setPlayers(listeners.count)
        return (id, stream)
    }

    public func detach(_ id: UUID) async {
        guard let continuation = listeners.removeValue(forKey: id) else { return }
        continuation.finish()
        await requester.setPlayers(listeners.count)
    }

    public var playerCount: Int { listeners.count }

    // MARK: - Signals

    /// The bus entry point: one raw `vision.signals.v1` payload.
    public func ingest(payload: Data) {
        guard let sample = VisionSignalSample.decode(payload) else {
            // Not a Signals message. Counted, not logged per frame — at 30 fps
            // a mismatched contract would otherwise write 30 lines a second to
            // core's captured stderr forever.
            undecodableSignals += 1
            return
        }
        ingest(sample: sample, at: BlinkClock.seconds(since: epoch))
    }

    /// The testable core. `at` is passed in rather than read from a clock so a
    /// test can drive a whole blink — or a five-second resting closure — in
    /// microseconds.
    public func ingest(sample: VisionSignalSample, at t: TimeInterval) {
        signalsReceived += 1
        lastSignalAt = Date()
        if sample.seq > 0 {
            if lastSeq > 0, sample.seq > lastSeq + 1 {
                droppedFrames += sample.seq - lastSeq - 1
            }
            lastSeq = sample.seq
        }

        lastEarL = sample.earL
        lastEarR = sample.earR

        let blink = detector.ingest(earL: sample.earL, earR: sample.earR, at: t)
        if let blink {
            // Emitted before the meter, and never throttled: this is the input
            // event the game is played with, and a late jump is a lost run.
            broadcast(.blink(BlinkUpdate(
                index: blink.index,
                closureMs: Int((blink.closure * 1000).rounded()),
                ear: blink.ear
            )))
        }
        emitMeterIfDue(at: t, force: blink != nil || detector.phase != lastPhase)
    }

    /// Watchdog step: notices that the provider has gone quiet. Nothing else
    /// can — `ingest` is only ever called when a message *did* arrive, so the
    /// absence of messages is invisible to it by construction.
    public func tick() {
        let t = BlinkClock.seconds(since: epoch)
        let changed = detector.tick(at: t)
        if changed { emitMeterIfDue(at: t, force: true) }
    }

    // MARK: - Config

    public func apply(thresholds: BlinkThresholds) {
        detector.apply(thresholds)
        emitMeterIfDue(at: BlinkClock.seconds(since: epoch), force: true)
    }

    // MARK: - Readouts

    public struct Snapshot: Codable, Sendable, Equatable {
        public var phase: String
        public var tracking: Bool
        public var ear: Double?
        public var blinks: Int
        public var players: Int
        public var signalsReceived: Int
        public var lastSignalAt: Date?
        public var droppedFrames: Int
        public var undecodableSignals: Int
        public var thresholds: BlinkThresholds
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            phase: detector.phase.rawValue,
            tracking: detector.isTracking,
            ear: detector.reading,
            blinks: detector.blinkCount,
            players: listeners.count,
            signalsReceived: signalsReceived,
            lastSignalAt: lastSignalAt,
            droppedFrames: Int(min(droppedFrames, UInt64(Int.max))),
            undecodableSignals: undecodableSignals,
            thresholds: detector.thresholds
        )
    }

    // MARK: - Internals

    private func currentMeter() -> MeterUpdate {
        // Per-eye values only while something is actually being measured:
        // reporting the last-seen pair alongside `tracking: false` would tell
        // the page a number that is no longer true of anybody's face.
        let tracking = detector.isTracking
        return MeterUpdate(
            ear: detector.reading,
            earL: tracking ? lastEarL : nil,
            earR: tracking ? lastEarR : nil,
            phase: detector.phase.rawValue,
            tracking: tracking,
            closeThreshold: detector.thresholds.close,
            openThreshold: detector.thresholds.open,
            blinks: detector.blinkCount,
            seq: lastSeq
        )
    }

    private func emitMeterIfDue(at t: TimeInterval, force: Bool) {
        guard force || t - lastMeterAt >= Self.meterInterval else { return }
        lastMeterAt = t
        lastPhase = detector.phase
        broadcast(.meter(currentMeter()))
    }

    private func broadcast(_ event: GameEvent) {
        for continuation in listeners.values { continuation.yield(event) }
    }
}
