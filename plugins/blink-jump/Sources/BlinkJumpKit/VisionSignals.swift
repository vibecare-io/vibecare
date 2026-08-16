import Foundation
import VCKStubs

/// Topic names, in one place. Both are declared in `manifest.yaml` — the
/// subscribe half and the publish half — and publishing a topic that is not in
/// `publishes` is a logged error and a *dropped message*, which here would
/// silently mean "vision never runs the model I need".
public enum VisionTopic {
    public static let signals = "vision.signals.v1"
    public static let face = "vision.face.v1"
    public static let request = "vision.request.v1"
}

/// The two numbers this plugin reads out of a `vision.signals.v1` payload.
///
/// A plain Swift value rather than the generated `VCTSignals`, so the wire
/// format stops at this file: everything downstream (the detector, the engine,
/// the tests) reasons about `Double?` and never has to remember that
/// `signals.earL` returns `0` for both "absent" and "genuinely zero".
public struct VisionSignalSample: Sendable, Equatable {
    /// `nil` means the field was ABSENT, which means the face model is not
    /// running (or found no face). It does NOT mean the eye is shut. Reading
    /// absent as `0.0` is the single easiest way to get this plugin wrong.
    public var earL: Double?
    public var earR: Double?
    /// `Header.seq`, shared by every topic derived from one frame. Only used
    /// here to make dropped frames visible in `/api/state`.
    public var seq: UInt64

    public init(earL: Double?, earR: Double?, seq: UInt64 = 0) {
        self.earL = earL
        self.earR = earR
        self.seq = seq
    }

    /// `nil` when the bytes are not a `Signals` message at all. An *empty*
    /// message is not that case: it decodes fine, to a sample with both ears
    /// absent, which is a valid statement meaning "nothing measured".
    public static func decode(_ payload: Data) -> VisionSignalSample? {
        guard let signals = try? VCTSignals(serializedBytes: payload) else { return nil }
        return VisionSignalSample(
            earL: signals.hasEarL ? Double(signals.earL) : nil,
            earR: signals.hasEarR ? Double(signals.earR) : nil,
            seq: signals.hasHeader ? signals.header.seq : 0
        )
    }
}

/// One `vision.request.v1` message, as desired state.
///
/// Latest-wins per `requester`, so this is always the *whole* intent and never
/// a delta: `topics: []` is a meaningful value that retracts everything this
/// plugin was asking for, and is exactly what closing the game publishes.
public struct VisionRequestIntent: Sendable, Equatable, Codable {
    /// Self-asserted and NOT authenticated — the bus event carries no
    /// publisher identity. Harmless, because the request can only ask for work
    /// that the kernel's demand refcount still gates.
    public var requester: String
    public var topics: [String]
    /// The provider runs `max()` across live requesters and caps capture at
    /// 30. A game wants faces fast; a 2 fps posture consumer sharing the
    /// provider is unaffected, since per-topic rates are independent.
    public var fps: UInt32
    /// Seconds the provider keeps this request without re-assertion. The
    /// backstop for a wedged consumer: if this process stops re-asserting for
    /// any reason, the camera closes on its own.
    public var ttlSeconds: UInt32

    public init(requester: String, topics: [String], fps: UInt32, ttlSeconds: UInt32) {
        self.requester = requester
        self.topics = topics
        self.fps = fps
        self.ttlSeconds = ttlSeconds
    }

    /// Serialized `vibecare.topics.v1.Request`, ready for `VCHost.publish`.
    ///
    /// Encoding failure is not a thing protobuf does for a message this shape
    /// (no required fields, no unset oneofs), and there is nothing useful to
    /// do about it here anyway — the caller's alternative would be to skip a
    /// heartbeat, which is strictly worse than sending an empty request that
    /// the provider ignores.
    public func encoded() -> Data {
        var request = VCTRequest()
        request.requester = requester
        request.topics = topics
        request.fps = fps
        request.ttlS = ttlSeconds
        return (try? request.serializedData()) ?? Data()
    }
}
