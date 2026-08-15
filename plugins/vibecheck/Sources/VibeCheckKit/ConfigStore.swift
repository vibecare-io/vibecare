import Foundation

public struct VibeCheckConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var sensitivity: Double
    public var dwell: TimeInterval
    public var cooldown: TimeInterval
    public var enabledBehaviors: [String]

    public init(
        enabled: Bool,
        sensitivity: Double,
        dwell: TimeInterval,
        cooldown: TimeInterval,
        enabledBehaviors: [String]
    ) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.dwell = dwell
        self.cooldown = cooldown
        self.enabledBehaviors = enabledBehaviors
    }

    /// Matches the values the client's view model used, except that dwell was
    /// hardcoded at 0.15 and is now configurable, and all of these were
    /// RAM-only and reset on every relaunch.
    public static let `default` = VibeCheckConfig(
        enabled: false,
        sensitivity: 0.5,
        dwell: 0.15,
        cooldown: 5,
        enabledBehaviors: BFRBBehavior.allCases.map(\.rawValue)
    )

    /// Clamps to the ranges the UI exposes, so a hand-edited file or a
    /// malformed PUT cannot put the detector into a nonsense state.
    public func clamped() -> VibeCheckConfig {
        var c = self
        c.sensitivity = min(1, max(0, sensitivity))
        c.cooldown = min(30, max(1, cooldown))
        c.dwell = min(5, max(0, dwell))
        return c
    }
}

public actor ConfigStore {
    private let url: URL
    private var cached: VibeCheckConfig

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("config.json")
        // A missing or corrupt file is not a reason to fail: refusing to
        // start would be an unrequested exit, and five of those park the
        // plugin in StateFailed until a manual dashboard restart.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VibeCheckConfig.self, from: data) {
            self.cached = decoded.clamped()
        } else {
            self.cached = .default
        }
    }

    public func load() -> VibeCheckConfig { cached }

    public func save(_ c: VibeCheckConfig) throws {
        let clamped = c.clamped()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clamped)
        // Atomic: a partially-written config that fails to parse on next
        // launch would silently reset every one of the user's settings.
        try data.write(to: url, options: .atomic)
        cached = clamped
    }
}
