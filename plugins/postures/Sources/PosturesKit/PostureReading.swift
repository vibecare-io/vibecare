import Foundation
import VCKStubs

// The measurement half of the vision design's §2 rule lives on the wire;
// everything below the decode is the JUDGEMENT half, which belongs here and
// must never be asked of vision:
//
//   vision publishes  shoulder_angle = 12°        (a property of the body)
//   postures decides  "that is slouching"          (an opinion about it)
//
// So `PostureSample` is a decode and nothing more, `PostureScore` is where
// the opinion starts, and neither of them knows how long anything has been
// true — that is `PosturePolicy`.

/// Indices into `VCTBodyPoseFrame.joints`, whose order is normative and
/// declared in `proto/topics/v1/vision.proto`. Only the ones this plugin
/// reads are named; the frame always carries all 19.
///
/// "left" and "right" are the SUBJECT's, which in viewer space appear on the
/// mirrored side of the image from where a naive read would put them. Nothing
/// here depends on which is which — a shoulder tilt is measured between the
/// two — but getting it wrong in a later change would flip the sign silently,
/// so it is written down.
public enum PostureJoint {
    public static let nose = 0
    public static let neck = 5
    public static let leftShoulder = 6
    public static let rightShoulder = 7

    /// Below this, a joint is Vision guessing rather than seeing. Body pose
    /// drops joints far more readily than hand pose does — a desk edge
    /// occludes both hips at once — and the proto contract is that undetected
    /// joints are still PRESENT, carrying a low confidence, so index 6 is
    /// always the left shoulder. Reading a low-confidence joint as a real
    /// measurement is how a plugin ends up nudging a user about the posture
    /// of their office chair.
    ///
    /// 0.3 is the threshold `VisionLandmarkExtractor` already ships for
    /// per-joint gating; reusing it keeps one number in the tree rather than
    /// two that drift.
    public static let minConfidence: Float = 0.3
}

/// One frame's worth of posture-relevant measurement, merged from whichever
/// of `vision.signals.v1` and `vision.body_pose.v1` described that frame.
///
/// **Every measurement is `Optional` and absent is NOT zero.** A signal is
/// absent when the model that feeds it is not running, and a consumer that
/// reads absent `shoulder_angle` as `0.0` sees perfectly level shoulders and
/// would report good posture for a user who is not even in the room. This is
/// the single most likely way to get a vision consumer wrong, which is why
/// the field is `Double?` all the way down to `PostureScore` rather than
/// being defaulted at the decode.
public struct PostureSample: Sendable, Equatable {
    /// `Header.seq` — shared by every topic derived from the same camera
    /// frame, which is what lets the two topics be merged at all.
    public var seq: UInt64
    /// Degrees off horizontal. `nil` means not measured this frame.
    public var shoulderAngle: Double?
    /// Normalized forward-head distance. `nil` means not measured this frame.
    public var neckForward: Double?
    /// `true`/`false` from a body-pose frame; `nil` when no body-pose frame
    /// described this seq at all, which is a different statement from "no
    /// body was there".
    public var bodyDetected: Bool?

    public init(seq: UInt64, shoulderAngle: Double? = nil,
                neckForward: Double? = nil, bodyDetected: Bool? = nil) {
        self.seq = seq
        self.shoulderAngle = shoulderAngle
        self.neckForward = neckForward
        self.bodyDetected = bodyDetected
    }

    /// Whether anything at all was measured. An empty sample is "we know
    /// nothing", never "everything is fine".
    public var hasMeasurement: Bool { shoulderAngle != nil || neckForward != nil }

    /// Decodes `vision.signals.v1`.
    ///
    /// `hasShoulderAngle` / `hasNeckForward` — the generated presence
    /// accessors — are what make this honest. `s.shoulderAngle` alone returns
    /// `0` for an absent field, indistinguishable from a genuinely level pair
    /// of shoulders.
    public static func from(signals s: VCTSignals) -> PostureSample {
        PostureSample(
            // NOTE: unlike the fields below, this does not check `hasHeader`.
            // An absent header would read as seq 0 and could then merge with
            // an unrelated body-pose frame that also defaulted to 0. Not
            // reachable today — vision stamps a header on every message — and
            // fixing it properly means making `seq` optional through the
            // tracker's merge, so it is recorded here rather than papered over.
            seq: s.header.seq,
            shoulderAngle: s.hasShoulderAngle ? Double(s.shoulderAngle) : nil,
            neckForward: s.hasNeckForward ? Double(s.neckForward) : nil,
            bodyDetected: nil
        )
    }
}

/// What a `vision.body_pose.v1` frame tells this plugin.
///
/// Two things, and only two: whether a body is in frame at all, and — as a
/// fallback for a provider that publishes joints but no signals — the
/// shoulder angle re-derived from the joints themselves. That re-derivation
/// is the vision design's §4.4 override ladder taken one rung down, not a
/// duplicate of vision's math: the points were computed for us anyway, and
/// the alternative is a plugin that silently reports "unknown" forever
/// against a provider that is working perfectly.
public struct BodyPoseReading: Sendable, Equatable {
    public let seq: UInt64
    /// An empty `joints` is the valid "no body detected" message; so is a
    /// full set of joints that are all below `minConfidence`.
    public let bodyDetected: Bool
    /// `nil` when either shoulder is missing or low-confidence.
    public let shoulderAngle: Double?

    public init(seq: UInt64, bodyDetected: Bool, shoulderAngle: Double?) {
        self.seq = seq
        self.bodyDetected = bodyDetected
        self.shoulderAngle = shoulderAngle
    }

    public init(_ frame: VCTBodyPoseFrame) {
        self.seq = frame.header.seq
        self.bodyDetected = frame.joints.contains { $0.confidence >= PostureJoint.minConfidence }
        self.shoulderAngle = Self.shoulderAngle(joints: frame.joints)
    }

    /// The shoulder line's angle off horizontal, in degrees, folded into
    /// `(-90, 90]`.
    ///
    /// Folded because the shoulder line is UNDIRECTED: which endpoint the
    /// contract calls "left" is a labelling choice, and a 175° result would
    /// mean the same physical tilt as -5° while reading as catastrophic to
    /// any threshold test.
    ///
    /// Viewer space has `y` pointing DOWN, so a positive angle means the
    /// subject's right shoulder sits lower on screen. Callers compare
    /// `abs(_:)` against the threshold — a tilt is a tilt either way — so the
    /// sign is carried for the readout and nothing else.
    public static func shoulderAngle(joints: [VCTJoint]) -> Double? {
        guard joints.count > PostureJoint.rightShoulder else { return nil }
        let left = joints[PostureJoint.leftShoulder]
        let right = joints[PostureJoint.rightShoulder]
        guard left.confidence >= PostureJoint.minConfidence,
              right.confidence >= PostureJoint.minConfidence else { return nil }

        let dx = Double(right.point.x - left.point.x)
        let dy = Double(right.point.y - left.point.y)
        // Both shoulders on the same pixel is not a measurement of anything;
        // `atan2(0, 0)` is defined (0) but the "angle" is meaningless.
        guard dx != 0 || dy != 0 else { return nil }
        return fold(atan2(dy, dx) * 180 / .pi)
    }

    static func fold(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var a = degrees
        while a > 90 { a -= 180 }
        while a <= -90 { a += 180 }
        return a
    }
}

/// Which measurements are out of range this frame. An `OptionSet` rather than
/// an enum because both can be true at once, and the alert copy says
/// something different when they are.
public struct PostureFaults: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let unevenShoulders = PostureFaults(rawValue: 1 << 0)
    public static let forwardHead = PostureFaults(rawValue: 1 << 1)

    /// Stable strings for `/api/state`. Not derived from the case names by
    /// reflection: this is a wire format, and a rename should be a decision
    /// rather than a side effect.
    public var names: [String] {
        var out: [String] = []
        if contains(.unevenShoulders) { out.append("unevenShoulders") }
        if contains(.forwardHead) { out.append("forwardHead") }
        return out
    }
}

/// The verdict for ONE frame. Three cases, not two, because "we could not
/// tell" has to be distinguishable from "posture is fine" — collapsing them
/// is what turns an absent signal into a clean bill of health.
public enum PostureVerdict: Sendable, Equatable {
    /// Nothing measurable: no signals for this frame, or a body-pose frame
    /// that saw no body. Never fires a nudge, and — after a grace period —
    /// breaks the dwell, because you cannot have been slouching during a
    /// stretch when nobody could see you.
    case unknown
    case good
    case poor(PostureFaults)

    /// For `/api/state`, where a client wants a word rather than a union.
    public var name: String {
        switch self {
        case .unknown: return "unknown"
        case .good: return "good"
        case .poor: return "poor"
        }
    }

    public var faults: PostureFaults {
        if case .poor(let f) = self { return f }
        return []
    }
}

/// Scores one sample against the user's thresholds. Pure, total, and the
/// whole product opinion in one function — which is exactly why it is a free
/// function on an enum rather than a method somewhere stateful.
public enum PostureScore {
    public static func verdict(for sample: PostureSample, config: PostureConfig) -> PostureVerdict {
        // An explicit "no body in frame" beats any stale-looking measurement
        // that arrived alongside it. `nil` is NOT this case — it only means
        // no body-pose frame described this seq.
        if sample.bodyDetected == false { return .unknown }

        var faults: PostureFaults = []
        var measured = false

        if let angle = sample.shoulderAngle {
            measured = true
            if abs(angle) > config.shoulderAngleThreshold { faults.insert(.unevenShoulders) }
        }
        if let neck = sample.neckForward {
            measured = true
            // One-sided on purpose: heads crane forward. A head BEHIND the
            // shoulders is unusual, but it is not the thing this plugin has
            // an opinion about, and flagging it would make `abs()` here read
            // as symmetric when the posture problem is not.
            if neck > config.neckForwardThreshold { faults.insert(.forwardHead) }
        }

        // The load-bearing line. With no measurement at all there is no
        // verdict — returning `.good` here would mean a vision provider that
        // stopped publishing signals silently certified the user's posture as
        // fine forever.
        guard measured else { return .unknown }
        return faults.isEmpty ? .good : .poor(faults)
    }
}

/// Merges the two subscribed topics into one sample per camera frame.
///
/// `Header.seq` is shared by every topic derived from one frame, so the merge
/// rule is simply: contributions whose seq does not match the newest message
/// are treated as ABSENT, not as stale-but-usable. Carrying a shoulder angle
/// forward from an earlier frame would manufacture a measurement the provider
/// did not make — the same failure as reading absent as zero, one step
/// removed.
///
/// Both topics are evaluated as they arrive rather than joined behind a
/// barrier: `PosturePolicy` is keyed on time, so ingesting the same frame
/// twice (once when signals land, once when body pose does) changes nothing,
/// whereas waiting for a partner message that a lazily-constructed model will
/// never send would stall the plugin indefinitely.
public struct PostureTracker: Sendable {
    private var signals: PostureSample?
    private var body: BodyPoseReading?

    public init() {}

    public mutating func ingest(signals s: PostureSample) -> PostureSample {
        signals = s
        return merged(seq: s.seq)
    }

    public mutating func ingest(bodyPose b: BodyPoseReading) -> PostureSample {
        body = b
        return merged(seq: b.seq)
    }

    private func merged(seq: UInt64) -> PostureSample {
        let s = signals?.seq == seq ? signals : nil
        let b = body?.seq == seq ? body : nil
        return PostureSample(
            seq: seq,
            // Signals win when present: they are vision's own math, computed
            // once for every consumer. The body-pose derivation is the
            // fallback rung, used only when the provider publishes joints
            // without signals.
            shoulderAngle: s?.shoulderAngle ?? b?.shoulderAngle,
            neckForward: s?.neckForward,
            bodyDetected: b?.bodyDetected
        )
    }
}
