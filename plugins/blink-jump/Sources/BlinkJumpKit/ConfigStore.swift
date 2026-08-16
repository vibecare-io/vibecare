import Foundation

/// Everything the player can change, and the only thing this plugin persists
/// besides the scoreboard.
public struct BlinkJumpConfig: Codable, Sendable, Equatable {
    public var thresholds: BlinkThresholds
    /// Face rate to ask the provider for while the game is open. 30 because a
    /// blink is ~100–300 ms and a game has a 16 ms frame budget: at 15 fps a
    /// short blink can land inside a single sample interval and never produce
    /// a below-threshold reading at all.
    public var fps: Int
    /// The open-eye EAR the Calibrate button measured, kept so the UI can show
    /// *why* the thresholds are where they are ("calibrated at 0.31") rather
    /// than presenting two bare numbers. `nil` until someone calibrates.
    public var baselineOpenEar: Double?
    public var calibratedAt: Date?

    public init(
        thresholds: BlinkThresholds = .default,
        fps: Int = 30,
        baselineOpenEar: Double? = nil,
        calibratedAt: Date? = nil
    ) {
        self.thresholds = thresholds
        self.fps = fps
        self.baselineOpenEar = baselineOpenEar
        self.calibratedAt = calibratedAt
    }

    public static let `default` = BlinkJumpConfig()

    public func clamped() -> BlinkJumpConfig {
        var c = self
        c.thresholds = thresholds.clamped()
        // Floor of 5 rather than 0: `fps: 0` means "the provider's default"
        // on the wire, and silently swapping the player's setting for
        // someone else's default is worse than clamping to a rate that is at
        // least honest about being slow.
        c.fps = min(30, max(5, fps))
        if let baseline = baselineOpenEar, !baseline.isFinite { c.baselineOpenEar = nil }
        return c
    }
}

/// `config.json` in `VIBECARE_DATA_DIR`.
///
/// No `UserDefaults` anywhere in this plugin: a plugin binary has no bundle
/// identifier, so `UserDefaults.standard` writes into whatever domain the
/// spawning process happens to own — which is core's, shared with every other
/// plugin.
public actor ConfigStore {
    private let url: URL
    private var cached: BlinkJumpConfig

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("config.json")
        // A missing or corrupt file is never a reason to fail construction.
        // Refusing to start is an unrequested exit, and five of those park the
        // plugin in StateFailed until someone restarts it by hand.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.blinkJump().decode(BlinkJumpConfig.self, from: data) {
            self.cached = decoded.clamped()
        } else {
            self.cached = .default
        }
    }

    public func load() -> BlinkJumpConfig { cached }

    /// Returns what was actually written — the clamped value, not the caller's
    /// — so an in-memory copy can never diverge from the file.
    @discardableResult
    public func save(_ config: BlinkJumpConfig) throws -> BlinkJumpConfig {
        let clamped = config.clamped()
        let encoder = JSONEncoder.blinkJump()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clamped)
        // Atomic: a half-written config that fails to parse next launch would
        // silently throw away the player's calibration.
        try data.write(to: url, options: .atomic)
        cached = clamped
        return clamped
    }
}

extension JSONDecoder {
    /// One decoder configuration, used by both stores and by the tests that
    /// read their files back off disk. `.iso8601` on both sides or `Date`
    /// round-trips silently wrong.
    ///
    /// Fractional seconds are accepted as well as rejected-by-default, because
    /// `/api/*` is the real interface and the most obvious way to produce a
    /// timestamp for it — JavaScript's `Date.toISOString()`, or anything that
    /// copies it — emits `…:00.000Z`. Foundation's plain `.iso8601` strategy
    /// refuses that, which would turn one extra field into a 400 on the whole
    /// config PUT.
    public static func blinkJump() -> JSONDecoder {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected an ISO-8601 timestamp, got \(text)"
            ))
        }
        return decoder
    }
}

extension JSONEncoder {
    public static func blinkJump() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
