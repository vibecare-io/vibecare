import Foundation

// The derived half of `/api/state`: the ordering, the warnings and the one
// sentence that IS this product's privacy surface (§7). All pure functions
// over `VisionState`, so every claim the UI makes has a test that can fail.

// MARK: - Topics

/// Names and orders the five publishable topics for display.
///
/// The order is the pipeline's own order (face, hands, body, segmentation,
/// then the derived signals tier), fixed here so the readout does not
/// reshuffle itself between polls just because the capture side iterates a
/// dictionary. An unrecognised topic is not dropped — a provider that grows a
/// sixth topic should show up in the readout the day it ships, not the day
/// this table is updated — it sorts last, alphabetically.
public enum VisionTopicCatalog {
    public static let face = "vision.face.v1"
    public static let hands = "vision.hands.v1"
    public static let bodyPose = "vision.body_pose.v1"
    public static let segmentation = "vision.segmentation.v1"
    public static let signals = "vision.signals.v1"

    /// Display order, and the exact set `plugins/vision/manifest.yaml`
    /// declares under `publishes:`.
    public static let ordered = [face, hands, bodyPose, segmentation, signals]

    private static let displayNames: [String: String] = [
        face: "face",
        hands: "hands",
        bodyPose: "body pose",
        segmentation: "segmentation",
        signals: "signals",
    ]

    /// `vision.body_pose.v1` -> `body pose`. The fallback strips the domain
    /// prefix and version suffix and unpicks the snake_case, which is right
    /// for any topic following §3's naming and merely unhelpful (never
    /// wrong) for one that does not.
    public static func displayName(for topic: String) -> String {
        if let known = displayNames[topic] { return known }
        var name = topic
        if name.hasPrefix("vision.") { name.removeFirst("vision.".count) }
        if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].hasPrefix("v") {
            name = String(name[..<dot])
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// Sorts by the canonical order above, unknown topics last and
    /// alphabetical among themselves.
    public static func sorted(_ topics: [VisionTopicStatus]) -> [VisionTopicStatus] {
        topics.sorted { lhs, rhs in
            let l = ordered.firstIndex(of: lhs.topic) ?? Int.max
            let r = ordered.firstIndex(of: rhs.topic) ?? Int.max
            if l != r { return l < r }
            return lhs.topic < rhs.topic
        }
    }
}

// MARK: - Warnings

public enum VisionWarningCode: String, Sendable, Codable {
    case subscriberWithNoRequest
    /// `vision.signals.v1` is wanted, but nothing is deriving it. Signals
    /// costs no inference of its own — it is arithmetic over landmarks — so a
    /// consumer that reaches it without any model topic running receives an
    /// empty stream forever. Distinct from `subscriberWithNoRequest` because
    /// it is fixed by naming MORE topics, not by publishing a first request.
    case signalsWithoutAnyModel
}

/// The wiring mistake §5.3 calls "the single most likely way to wire a new
/// consumer up wrong", made visible.
///
/// Demand governs whether vision *may* run a model; the request union governs
/// whether it *does*. A consumer that declares `subscribes: [vision.face.v1]`
/// and never publishes a `vision.request.v1` sits there receiving nothing at
/// all, which is indistinguishable from a broken bus. So this is not
/// decoration on a log line: it is the only thing in the system that can tell
/// that consumer's author what they forgot.
public struct VisionWarning: Sendable, Equatable {
    public var code: VisionWarningCode
    public var topic: String
    public var subscribers: Int

    /// The human sentence, shown in the tab and in `/api/state`.
    public var message: String {
        switch code {
        case .subscriberWithNoRequest:
            let plural = subscribers == 1 ? "plugin subscribes" : "plugins subscribe"
            return "\(subscribers) \(plural) to \(topic) but no live vision.request.v1 names it, "
                + "so nothing is published. The subscriber must publish a request naming this topic "
                + "(and declare vision.request.v1 in its manifest's publishes list)."
        case .signalsWithoutAnyModel:
            let plural = subscribers == 1 ? "plugin subscribes" : "plugins subscribe"
            return "\(subscribers) \(plural) to \(topic), but no model is running to derive it from, "
                + "so nothing is published and the camera stays closed. Signals costs no inference "
                + "of its own — it is arithmetic over landmarks. The request must name the model "
                + "topics it needs too (vision.face.v1 for the eye and head signals, "
                + "vision.body_pose.v1 for the posture ones)."
        }
    }

    /// The stderr line, in exactly the shape §5.3 specifies. Kept next to
    /// `message` so the log and the readout can never drift apart: whoever
    /// logs this — the capture side, on transition, rather than this target
    /// on every `/api/state` poll — logs THIS string.
    public var logLine: String {
        switch code {
        case .subscriberWithNoRequest:
            return "subscriber with no request topic=\(topic) subscribers=\(subscribers)"
        case .signalsWithoutAnyModel:
            return "request names only \(topic) topic=\(topic) subscribers=\(subscribers)"
                + " — signals costs no inference, so nothing derives it and the camera stays closed;"
                + " the requester must also name the model topics it wants run"
        }
    }

    public init(code: VisionWarningCode, topic: String, subscribers: Int) {
        self.code = code
        self.topic = topic
        self.subscribers = subscribers
    }

    /// One warning per topic whose demand is non-zero while no live request
    /// names it.
    ///
    /// Note what is deliberately NOT a condition: `isRunning`. A topic can be
    /// non-running for the perfectly ordinary reason that nobody wants it
    /// (zero subscribers, zero requesters), and warning about that would bury
    /// the real signal under three permanent false positives on a fresh
    /// install. It is the *combination* — someone is listening, nobody asked
    /// — that is always a bug.
    public static func derive(from topics: [VisionTopicStatus]) -> [VisionWarning] {
        // Signals is the one topic that can be wanted, granted by both halves
        // of the floor, and still produce nothing — it has no model of its
        // own, so with no landmark model running there is no arithmetic to
        // do. That consumer needs to hear "name more topics", not "publish a
        // request", so it gets its own code.
        let anyModelRunning = topics.contains { $0.isRunning && $0.topic != VisionTopicCatalog.signals }
        return VisionTopicCatalog.sorted(topics)
            .filter { $0.subscribers > 0 && $0.requesters.isEmpty }
            .map { status in
                let code: VisionWarningCode =
                    (status.topic == VisionTopicCatalog.signals && !anyModelRunning)
                        ? .signalsWithoutAnyModel
                        : .subscriberWithNoRequest
                return VisionWarning(code: code, topic: status.topic, subscribers: status.subscribers)
            }
    }
}

// MARK: - Summary

/// The privacy sentence: one line that says why the camera is on and who
/// wanted it. §7 names this the whole point of the tab, so it is derived
/// here, tested here, and served by `/api/state` — not assembled in
/// JavaScript where only a browser could ever check it.
public enum VisionSummary {
    public static func line(camera: VisionCameraState, topics: [VisionTopicStatus]) -> String {
        let running = VisionTopicCatalog.sorted(topics).filter(\.isRunning)

        guard camera.isOpen else {
            switch camera.permission {
            case .denied, .restricted:
                return "The camera is off — access is denied, so nothing can run."
            case .noDevice:
                return "The camera is off — no camera is attached."
            case .authorized, .notDetermined:
                return running.isEmpty
                    ? "The camera is off. No models are running and no plugin has asked for one."
                    // Requests outliving the session is a real, transient
                    // state (the session is starting, or demand just went to
                    // zero underneath a live request), and saying "off" while
                    // listing running models would read as a contradiction.
                    : "The camera is off. \(clause(for: running)) — starting up."
            }
        }

        guard !running.isEmpty else {
            // Never expected: the session has no reason to be open with
            // nothing running. Said plainly rather than hidden, because an
            // open camera nobody asked for is the exact failure the privacy
            // readout exists to catch.
            return "The camera is on but no models are running."
        }
        return "The camera is on because \(clause(for: running))."
    }

    /// "postures wants body pose" · "vibecheck and blink-jump want face" ·
    /// several clauses joined with "; ".
    private static func clause(for running: [VisionTopicStatus]) -> String {
        running.map { status in
            let who = requesterPhrase(status.requesters)
            // `> 1`, not `== 1`: the zero case renders as the singular
            // "an unnamed requester", so it takes the singular verb too.
            let verb = status.requesters.count > 1 ? "want" : "wants"
            return "\(who) \(verb) \(VisionTopicCatalog.displayName(for: status.topic))"
        }
        .joined(separator: "; ")
    }

    private static func requesterPhrase(_ requesters: [String]) -> String {
        let names = requesters.sorted()
        switch names.count {
        case 0:
            // Running with nobody claiming it. `Request.requester` is
            // self-asserted (§5.3) and a consumer can publish an empty one,
            // so this is reachable and must not render as an empty string.
            return "an unnamed requester"
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
