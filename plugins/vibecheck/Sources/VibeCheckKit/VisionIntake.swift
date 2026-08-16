import Foundation
import VCKStubs
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — see the identical
/// rule and reasoning in every other file of this package.
private func intakeLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// What `VisionFrameJoiner` reports about the stream, surfaced by
/// `GET /api/state` so "the detector is on but nothing is happening" has an
/// answer other than guessing.
///
/// `skipped` is the load-bearing number. Frames are dropped here for exactly
/// one reason — a set that never completed before the bounded buffer had to
/// evict it — which is what a slow subscriber, or a provider running one of
/// the requested topics at a lower rate than the others, looks like from
/// this side.
public struct VisionLinkStats: Codable, Sendable, Equatable {
    public var requiredTopics: [String]
    public var joined: Int
    public var skipped: Int
    public var lastSeq: UInt64?

    public init(requiredTopics: [String] = [], joined: Int = 0, skipped: Int = 0, lastSeq: UInt64? = nil) {
        self.requiredTopics = requiredTopics
        self.joined = joined
        self.skipped = skipped
        self.lastSeq = lastSeq
    }
}

/// Joins `vision.face.v1` / `vision.hands.v1` / `vision.segmentation.v1` by
/// `Header.seq` and emits only COMPLETE sets.
///
/// ## Why a join at all
///
/// `BFRBDetector` measures a fingertip against a nose, a mouth and a hair
/// silhouette. Those three arrive as three separate bus messages, and the
/// bus makes no ordering or delivery promise across topics — events are
/// ephemeral, and a slow subscriber is dropped rather than buffered. So the
/// three parts of one capture frame can arrive out of order, and any one of
/// them can simply never arrive. Evaluating whatever happens to be latest
/// per topic would mean testing this frame's fingertip against the previous
/// frame's hair mask, which is a false positive waiting to happen every time
/// the user's hand moves fast. `Header.seq` is shared by every topic derived
/// from one frame precisely so this join is possible; a frame whose
/// segmentation was dropped is SKIPPED.
///
/// ## Why the buffer is bounded
///
/// The bus drops slow subscribers rather than buffering without bound, and a
/// consumer that does the opposite has merely moved the leak. `maxPending`
/// sets of partial frames is a little over half a second at 15fps, which is
/// far longer than any real inter-topic skew and far shorter than anything
/// that could grow. Eviction is oldest-seq-first and counted, never silent.
public actor VisionFrameJoiner {
    /// How many incomplete sequence numbers may be held at once. Eight is
    /// ~0.5s at the 15fps this plugin requests: long enough to absorb a
    /// slower segmentation topic, short enough that a permanently missing
    /// topic shows up as a rising `skipped` within a second rather than as
    /// memory growth.
    public static let maxPending = 8

    private struct Partial {
        var face: VCTFaceFrame?
        var hands: VCTHandsFrame?
        var segmentation: VCTSegmentationFrame?

        func has(_ topic: VisionTopic) -> Bool {
            switch topic {
            case .face: return face != nil
            case .hands: return hands != nil
            case .segmentation: return segmentation != nil
            }
        }
    }

    /// The topics a set must contain before it counts as complete. Kept in
    /// lockstep with what `VisionRequest` actually asked the provider for —
    /// requiring a topic nobody requested would wedge the join permanently,
    /// and requiring less than was requested would evaluate hair-pulling
    /// against a missing mask.
    private var required: Set<VisionTopic> = []
    private var pending: [UInt64: Partial] = [:]
    private var lastEmittedSeq: UInt64?
    private var joined = 0
    private var skipped = 0
    private var lastAnchorSource: FaceAnchors.Source?

    public init() {}

    public func stats() -> VisionLinkStats {
        VisionLinkStats(
            requiredTopics: required.map(\.rawValue).sorted(),
            joined: joined,
            skipped: skipped,
            lastSeq: lastEmittedSeq
        )
    }

    /// Re-points the join at a new completeness rule.
    ///
    /// Everything half-built under the old rule is dropped and counted as
    /// skipped rather than re-evaluated. That costs at most `maxPending`
    /// partial sets — half a second of frames, at the exact instant the user
    /// moved a toggle and is not looking for a detection anyway — and it
    /// buys the join a straight-line dependency: the rule changes here and
    /// completed frames leave by exactly one door, `ingest`. Re-evaluating
    /// in place would have to hand frames back to the detector from a call
    /// made BY the publisher that the detector's own config change drove,
    /// which is a cycle for no user-visible gain.
    public func setRequired(_ topics: Set<VisionTopic>) {
        guard topics != required else { return }
        required = topics
        skipped += pending.count
        pending.removeAll()
    }

    /// Decodes one bus event and folds it into the join. Returns a frame
    /// only when this event completed a set.
    ///
    /// A payload that fails to decode is dropped with a log line and nothing
    /// else: it cannot be a reason to exit (core charges any unrequested
    /// exit as a failed start), and it must not poison the seq it belonged
    /// to — a garbled face message on frame 41 should not stop frame 42 from
    /// being evaluated.
    public func ingest(topic: String, payload: Data) -> VisionFrame? {
        guard let visionTopic = VisionTopic(rawValue: topic) else { return nil }
        // Required is the union we asked for; a topic outside it is being
        // delivered because some OTHER consumer asked for it. Holding it
        // would grow `pending` for sets that can never complete under our
        // own rule.
        guard required.contains(visionTopic) else { return nil }

        var partial: Partial
        let seq: UInt64
        do {
            switch visionTopic {
            case .face:
                let message = try VCTFaceFrame(serializedBytes: payload)
                seq = message.header.seq
                guard admits(seq) else { return nil }
                partial = pending[seq] ?? Partial()
                partial.face = message
            case .hands:
                let message = try VCTHandsFrame(serializedBytes: payload)
                seq = message.header.seq
                guard admits(seq) else { return nil }
                partial = pending[seq] ?? Partial()
                partial.hands = message
            case .segmentation:
                let message = try VCTSegmentationFrame(serializedBytes: payload)
                seq = message.header.seq
                guard admits(seq) else { return nil }
                partial = pending[seq] ?? Partial()
                partial.segmentation = message
            }
        } catch {
            intakeLog("could not decode \(topic): \(error)")
            return nil
        }

        pending[seq] = partial
        if isComplete(partial) {
            let frame = emit(seq)
            noteAnchorSource(frame)
            return frame
        }
        evictOverflow()
        return nil
    }

    /// Whether a sequence number may still be joined.
    ///
    /// Two different things look like "older than the last frame emitted",
    /// and conflating them is a bug either way round:
    ///
    ///  * a STRAGGLER — the last topic of a set that was already retired —
    ///    must be refused, or dwell gets double-counted for a moment that
    ///    has already passed;
    ///  * a PROVIDER RESTART must be accepted. `Header.seq` is monotonic per
    ///    provider, not globally, so a vision process that crashes and is
    ///    respawned starts counting from the beginning again. Refusing those
    ///    on the "older" rule would wedge this join permanently: detection
    ///    would go dead after any provider restart and stay dead, with
    ///    nothing in the log but silence.
    ///
    /// A backwards jump of more than the buffer depth cannot be a straggler
    /// — nothing that old is still pending — so it is read as the restart it
    /// is, and the join starts over.
    private func admits(_ seq: UInt64) -> Bool {
        guard let last = lastEmittedSeq else { return true }
        if seq > last { return true }
        guard last - seq > UInt64(Self.maxPending) else { return false }
        intakeLog("vision seq jumped backwards (\(last) -> \(seq)); treating it as a provider restart and re-joining from here")
        lastEmittedSeq = nil
        pending.removeAll()
        return true
    }

    /// Logs once per transition when the face anchors come from the bounding
    /// box rather than the landmark cloud — the symptom of this plugin's
    /// constellation layout disagreeing with what the provider actually
    /// publishes. Silent degradation would look exactly like "detection got
    /// less sensitive", with nothing to grep for.
    private func noteAnchorSource(_ frame: VisionFrame) {
        guard let source = frame.face?.source, source != lastAnchorSource else { return }
        lastAnchorSource = source
        switch source {
        case .bounds:
            intakeLog("face anchors fell back to the bounding box — FaceFrame.points did not match a known constellation layout, or the indexed points were not a plausible nose/mouth")
        case .landmarks:
            intakeLog("face anchors are reading FaceFrame.points")
        }
    }

    private func isComplete(_ partial: Partial) -> Bool {
        !required.isEmpty && required.allSatisfy(partial.has)
    }

    private func emit(_ seq: UInt64) -> VisionFrame {
        let partial = pending.removeValue(forKey: seq)
        lastEmittedSeq = seq
        joined += 1
        // Everything still buffered is older than what we just emitted and
        // can never complete without a message `admits` will now refuse.
        // Counting them here is what makes `skipped` mean "frames the join
        // gave up on" rather than "frames the buffer ran out of room for".
        let stale = pending.keys.filter { $0 < seq }
        for key in stale { pending.removeValue(forKey: key) }
        skipped += stale.count
        return VisionFrame(face: partial?.face, hands: partial?.hands, segmentation: partial?.segmentation)
    }

    private func evictOverflow() {
        while pending.count > Self.maxPending, let oldest = pending.keys.min() {
            pending.removeValue(forKey: oldest)
            skipped += 1
        }
    }
}

// MARK: - The event loop

/// Reads everything core delivers on the Register stream and routes it: bus
/// payloads into the join and on to the detector, and the reserved demand
/// topic into a re-assertion of this plugin's `vision.request.v1`.
///
/// ## Why demand is the reconnect signal
///
/// The design says the request must be re-asserted "on every reconnect", and
/// `VCHost` deliberately exposes no reconnect callback — its ladder is
/// internal, and `events()` runs unbroken across a re-registration. What
/// core DOES do on every fresh Register stream is re-announce demand for
/// every topic this plugin publishes, as a full burst (that is documented
/// behaviour, not an accident: demand is authoritative state, not a delta).
/// A plugin that declares `publishes: [vision.request.v1, …]` therefore sees
/// exactly one thing on reconnect and nothing else, which makes that burst
/// the only honest reconnect signal available. The 10s heartbeat in
/// `VisionRequest` is the backstop for anything this misses — at a 30s TTL
/// it has three tries.
public struct VisionIntake: Sendable {
    private let joiner: VisionFrameJoiner
    private let engine: DetectionEngine
    private let request: VisionRequest

    public init(joiner: VisionFrameJoiner, engine: DetectionEngine, request: VisionRequest) {
        self.joiner = joiner
        self.engine = engine
        self.request = request
    }

    /// Runs until the stream finishes, which `VCHost` does only on shutdown.
    /// Never throws and never exits the process: a malformed event is
    /// dropped, not fatal.
    public func run(_ events: AsyncStream<VCEvent>) async {
        for await event in events {
            if event.topic == VCTopicDemand {
                await request.reassert(reason: "demand announcement (a reconnect re-announces every topic)")
                continue
            }
            if let frame = await joiner.ingest(topic: event.topic, payload: event.payload) {
                await engine.ingest(frame)
            }
        }
    }
}
