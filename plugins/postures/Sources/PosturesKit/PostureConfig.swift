import Foundation

/// Everything the user can change about posture nudging, persisted as JSON in
/// `$VIBECARE_DATA_DIR/config.json`.
///
/// Deliberately thresholds rather than one abstract "sensitivity" dial: the
/// two numbers vision publishes (`shoulder_angle` in degrees, `neck_forward`
/// normalized) have units, and a slider labelled 0..1 would hide them behind
/// a mapping nobody could reason about. A user who thinks "my shoulders tilt
/// a bit, that's just how I sit" can raise exactly the number that means that.
public struct PostureConfig: Codable, Sendable, Equatable {
    /// Off by default. `enabled` is the user intent that
    /// `vision.request.v1` broadcasts (spec §5.2): disabled means postures
    /// publishes `{topics: []}`, vision destroys the body-pose model, and if
    /// no other consumer wants anything the capture session stops and the
    /// camera LED goes out. A feature that opted itself in would take the
    /// camera with it.
    public var enabled: Bool

    /// Degrees off horizontal, beyond which the shoulder line reads as
    /// uneven. Compared against `abs(shoulder_angle)` — a tilt is a tilt in
    /// either direction.
    public var shoulderAngleThreshold: Double

    /// Normalized forward-head distance, beyond which the head reads as
    /// craned over the keyboard. One-sided: heads lean forward, and a
    /// negative value (head behind the shoulders) is not a posture problem
    /// this plugin has an opinion about.
    public var neckForwardThreshold: Double

    /// Seconds of SUSTAINED poor posture before a nudge is earned. Two
    /// minutes by default, because everyone leans forward to read something
    /// and nobody wants to be told about it.
    public var dwell: TimeInterval

    /// Seconds of silence after a nudge, however bad posture stays. Fifteen
    /// minutes by default. This is the whole anti-nag mechanism: without it,
    /// a user who genuinely sits badly would be told so every two minutes
    /// forever and would turn the plugin off inside an hour.
    public var cooldown: TimeInterval

    public init(
        enabled: Bool,
        shoulderAngleThreshold: Double,
        neckForwardThreshold: Double,
        dwell: TimeInterval,
        cooldown: TimeInterval
    ) {
        self.enabled = enabled
        self.shoulderAngleThreshold = shoulderAngleThreshold
        self.neckForwardThreshold = neckForwardThreshold
        self.dwell = dwell
        self.cooldown = cooldown
    }

    public static let `default` = PostureConfig(
        enabled: false,
        shoulderAngleThreshold: 8,
        neckForwardThreshold: 0.18,
        dwell: 120,
        cooldown: 900
    )

    /// Clamps to the ranges the UI exposes, so a hand-edited file or a
    /// malformed PUT cannot put the policy into a nonsense state — a dwell of
    /// zero would fire on the first poor frame, and a cooldown of zero would
    /// fire on every frame after that.
    ///
    /// A non-finite value is replaced with the default rather than clamped.
    /// `NaN` survives `min`/`max` unchanged — every comparison against it is
    /// false — and would then make every threshold test false forever, so the
    /// plugin would look perfectly healthy and never nudge again. Infinity
    /// would clamp correctly, but it is rejected the same way: it was clearly
    /// never typed by a human, and the default is a saner answer than the
    /// widest value the UI allows.
    public func clamped() -> PostureConfig {
        var c = self
        c.shoulderAngleThreshold = Self.clamp(shoulderAngleThreshold,
                                              1, 45, Self.default.shoulderAngleThreshold)
        c.neckForwardThreshold = Self.clamp(neckForwardThreshold,
                                            0.02, 1, Self.default.neckForwardThreshold)
        c.dwell = Self.clamp(dwell, 5, 3600, Self.default.dwell)
        c.cooldown = Self.clamp(cooldown, 30, 21600, Self.default.cooldown)
        return c
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double,
                              _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(high, max(low, value))
    }
}

/// The persisted `PostureConfig`, cached in memory and written atomically.
///
/// Same discipline as every other store in this tree: a missing or corrupt
/// file yields defaults instead of throwing. Refusing to start because a
/// config file got truncated would be an unrequested exit, and
/// `supervisor.go` charges five of those into `StateFailed` until a manual
/// dashboard restart.
public actor ConfigStore {
    private let url: URL
    private var cached: PostureConfig

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(PostureConfig.self, from: data) {
            self.cached = decoded.clamped()
        } else {
            self.cached = .default
        }
    }

    public func load() -> PostureConfig { cached }

    public func save(_ c: PostureConfig) throws {
        let clamped = c.clamped()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clamped)
        // Atomic: a half-written config that fails to parse on next launch
        // would silently reset every one of the user's settings.
        try data.write(to: url, options: .atomic)
        cached = clamped
    }
}
