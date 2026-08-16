import Foundation
import VCPluginSDK

/// The liveness half of the control plane: the kernel's per-topic subscriber
/// refcount, delivered on the reserved `_core.demand.v1` topic.
///
/// Two properties of that channel shape this type entirely:
///
/// * **Demand is authoritative STATE, not a delta.** Every event carries one
///   topic's absolute subscriber count, so `apply` overwrites rather than
///   adding. Transitions that happen while the Register stream is down are
///   dropped and never replayed, and a full burst arrives on reconnect —
///   which is harmless precisely because each event is a whole truth about
///   one topic.
/// * **Only a `publishes` declaration earns it.** A plugin with an empty
///   `publishes` list never receives demand at all, and declaring
///   `_core.demand.v1` in `subscribes` does nothing. This plugin publishes all
///   five `vision.*` topics, so it hears about all five.
///
/// Demand cannot know **intent**: subscriber count is a manifest-declared
/// subscription plus an open Register stream, so a user who switches a
/// detector off in that detector's own UI leaves the process up and subscribed
/// and the count at 1. That gap is what `RequestRegistry` covers. What demand
/// *can* do, and requests cannot, is close the camera when a consumer dies
/// without retracting — which is why it is the privacy **floor** and not
/// merely one more input.
public struct DemandTable: Sendable, Equatable {
    private var counts: [String: Int] = [:]

    public init() {}

    /// Overwrites this topic's count. Never accumulates: see the type comment.
    public mutating func apply(topic: String, subscribers: Int) {
        counts[topic] = max(0, subscribers)
    }

    public mutating func apply(_ demand: VCDemand) {
        apply(topic: demand.topic, subscribers: demand.subscribers)
    }

    /// Decodes and applies a `_core.demand.v1` payload (JSON:
    /// `{"topic":…,"subscribers":…}`). Returns the decoded value, or `nil` if
    /// the payload was unreadable — which is logged and otherwise ignored,
    /// because a malformed kernel message is not a reason to tear anything
    /// down.
    @discardableResult
    public mutating func apply(payload: Data) -> VCDemand? {
        guard let demand = try? JSONDecoder().decode(VCDemand.self, from: payload) else {
            visionLog("undecodable \(VCTopicDemand) payload (\(payload.count) bytes); ignoring")
            return nil
        }
        apply(demand)
        return demand
    }

    public func subscribers(_ topic: VisionTopic) -> Int { counts[topic.name] ?? 0 }

    public func subscribers(topic: String) -> Int { counts[topic] ?? 0 }

    /// True when **every** `vision.*` topic is at zero subscribers. This is
    /// the demand floor: when it holds, the capture session stops and the LED
    /// goes off regardless of what any stale request still asks for.
    public var isSilent: Bool {
        VisionTopic.allCases.allSatisfy { subscribers($0) == 0 }
    }

    /// Per-topic counts in a stable order, for the readout.
    public var byTopic: [VisionTopic: Int] {
        VisionTopic.allCases.reduce(into: [:]) { $0[$1] = subscribers($1) }
    }
}
