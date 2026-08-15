import Foundation

public struct VCAlertAction: Sendable, Codable, Equatable {
    public var label: String
    public var url: String          // plugin-relative; core routes to /p/<id>/<url>
    public init(label: String, url: String) { self.label = label; self.url = url }
}

public struct VCAlert: Sendable, Equatable {
    public var title: String
    public var body: String
    public var level: String        // "info" | "warn" — nothing else exists
    public var actions: [VCAlertAction]
    public init(title: String, body: String, level: String = "info",
                actions: [VCAlertAction] = []) {
        self.title = title; self.body = body; self.level = level; self.actions = actions
    }
}

public struct VCEvent: Sendable {
    public let topic: String
    public let payload: Data
    /// `nil` when core sent no timestamp. Deliberately optional rather than
    /// defaulted to `Date()`: a plugin that windows on event time needs to
    /// know the difference between "core said 12:04" and "we made this up".
    public let ts: Date?

    public init(topic: String, payload: Data, ts: Date?) {
        self.topic = topic; self.payload = payload; self.ts = ts
    }
}

/// Delivered on the reserved topic `_core.demand.v1` without being declared
/// in the manifest. Authoritative STATE, not a delta: overwrite local state
/// from every event, and expect a full burst on reconnect. Transitions that
/// happen while the stream is down are dropped and never replayed.
///
/// Note: a plugin with an empty `publishes` list never receives this at all,
/// and declaring the topic in `subscribes` does nothing — announceDemand
/// writes straight to the publisher's channel.
public struct VCDemand: Sendable, Codable, Equatable {
    public let topic: String
    public let subscribers: Int

    public init(topic: String, subscribers: Int) {
        self.topic = topic; self.subscribers = subscribers
    }
}

public let VCTopicDemand = "_core.demand.v1"

public struct VCHealthBody: Sendable, Codable, Equatable {
    public var status: String       // "ok" | "degraded"
    public var detail: String

    public init(status: String, detail: String) {
        self.status = status; self.detail = detail
    }

    /// Core force-clears detail on any transition to `up` (health.go:179-181),
    /// so a detail carried alongside "ok" is silently discarded. Drop it here
    /// rather than emitting something the operator will never see.
    public func normalized() -> VCHealthBody {
        status == "ok" ? VCHealthBody(status: "ok", detail: "") : self
    }
}

public enum VCHostError: Error, Equatable, CustomStringConvertible {
    /// The register response sequence finished without throwing. Never
    /// actually thrown by the session loop — the loop treats a clean end and
    /// a thrown error identically — but kept as a nameable value so that
    /// equivalence is assertable.
    case streamEnded
    /// Core asked us to stop, either with `CoreMsg.shutdown` or SIGTERM.
    case shutdownRequested
    /// Core did not send `Ready` inside the ready budget. Retryable: the
    /// registration may simply have raced a core restart.
    case readyTimeout
    /// Core answered `Register` with a status it will keep answering with
    /// (`NOT_FOUND` for an id it never discovered). Still retryable — a core
    /// restart with a corrected manifest must recover the plugin without
    /// restarting the plugin process.
    case registrationRejected(String)
    /// `publish`/`alert` were called while no gRPC client existed — the gap
    /// between transport rebuilds, or before the first dial. Not the same as
    /// "the Register stream is down": both RPCs work fine across a Register
    /// reconnect, because core checks only the manifest id for them.
    case notConnected

    public var description: String {
        switch self {
        case .streamEnded: return "the register stream ended cleanly"
        case .shutdownRequested: return "core requested shutdown"
        case .readyTimeout: return "core did not acknowledge registration in time"
        case .registrationRejected(let why): return "core rejected registration: \(why)"
        case .notConnected: return "no connection to core"
        }
    }
}

public enum VCSessionOutcome: Equatable {
    case reconnect
    case stop

    /// A clean end and a thrown error both mean the same thing: get back on
    /// the ladder. Only an explicit shutdown stops.
    ///
    /// This exists as a free function on a value type, rather than as `if`
    /// statements welded into the loop, precisely so the clean-end case is
    /// assertable without a network.
    public static func classify(error: Error?) -> VCSessionOutcome {
        if let e = error as? VCHostError, e == .shutdownRequested { return .stop }
        return .reconnect
    }
}
