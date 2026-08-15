import Foundation

// MARK: - Notification Position

/// Byte-compatible copy of the client's `NotificationPosition`
/// (`vibecare/Models/NotificationPreferences.swift`) — same case names,
/// same raw values — so a decoded blob from the client's
/// `vibecheck.alert.preferences` UserDefaults key round-trips without
/// migration.
public enum NotificationPosition: String, Codable, CaseIterable, Sendable, Equatable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

// MARK: - Blur Intensity

/// Byte-compatible copy of the client's `BlurIntensity`. Matches VibeNotify
/// 0.0.5's `ScreenBlurIntensity` enum, per the client's own comment.
public enum BlurIntensity: String, Codable, CaseIterable, Sendable, Equatable {
    case light
    case medium
    case heavy
}

// MARK: - Notification Preferences

/// A local, value-type copy of the client's `NotificationPreferences`
/// (`clients/macos-swift/VibeCare/vibecare/Models/NotificationPreferences.swift`).
///
/// Field names and types are kept byte-compatible on purpose: an existing
/// user's `vibecheck.alert.preferences` blob — `[String: NotificationPreferences]`
/// keyed by `BFRBBehavior.rawValue` — must decode here without migration.
/// The client's version is a `@Observable` reference type with synthesized
/// Codable (no custom `CodingKeys`); this is a plain `Struct` with the same
/// stored properties in the same order, which the JSON coders treat
/// identically since Codable dictionaries and structs are keyed, not
/// positional. `CGFloat` fields become `Double` — `CGFloat: Codable` itself
/// encodes as a single `Double` container, so the wire shape is unchanged.
public struct NotificationPreferences: Codable, Sendable, Equatable {
    public var bundledIconId: String?
    public var svgPath: String?
    public var svgWidth: Double?
    public var svgHeight: Double?
    public var title: String?
    public var message: String?
    public var position: NotificationPosition
    public var width: Double?
    public var height: Double?
    public var moveable: Bool
    public var autoDismissAfter: TimeInterval?
    public var screenBlurEnabled: Bool
    public var screenBlurIntensity: BlurIntensity

    public init(
        bundledIconId: String? = nil,
        svgPath: String? = nil,
        svgWidth: Double? = nil,
        svgHeight: Double? = nil,
        title: String? = nil,
        message: String? = nil,
        position: NotificationPosition = .center,
        width: Double? = nil,
        height: Double? = nil,
        moveable: Bool = true,
        autoDismissAfter: TimeInterval? = 20.0,
        screenBlurEnabled: Bool = false,
        screenBlurIntensity: BlurIntensity = .medium
    ) {
        self.bundledIconId = bundledIconId
        self.svgPath = svgPath
        self.svgWidth = svgWidth
        self.svgHeight = svgHeight
        self.title = title
        self.message = message
        self.position = position
        self.width = width
        self.height = height
        self.moveable = moveable
        self.autoDismissAfter = autoDismissAfter
        self.screenBlurEnabled = screenBlurEnabled
        self.screenBlurIntensity = screenBlurIntensity
    }

    /// Matches the client's `NotificationPreferences.default` base values.
    public static let base = NotificationPreferences(
        position: .center,
        width: 450,
        height: 220,
        moveable: true,
        autoDismissAfter: 20.0,
        screenBlurEnabled: false,
        screenBlurIntensity: .medium
    )

    /// Matches `DetectionAlertPreferencesStore.makeDefault(for:)`: bundled
    /// icon + mild (light) screen blur, everything else from `base`.
    ///
    /// `svgPath` is the one deliberate departure from the client. The client
    /// builds an absolute URL via `NetworkConfiguration.buildIconURL`
    /// (`<backend_url>/api/icons/<id>.svg`), because it knows its own
    /// `backend_url` setting. The plugin has no such setting and is mounted
    /// at a path — `/p/vibecheck/` — it must not know about, so the default
    /// points at a plugin-relative path instead; whatever serves the plugin's
    /// UI is responsible for resolving `icons/<id>.svg` under its own mount.
    public static func `default`(for behavior: BFRBBehavior) -> NotificationPreferences {
        var p = base
        p.svgPath = "icons/\(behavior.defaultIconId).svg"
        p.svgWidth = 220
        p.svgHeight = 150
        p.screenBlurEnabled = true
        p.screenBlurIntensity = .light
        return p
    }
}

// MARK: - Store

/// Per-behavior alert preferences, file-backed the same way `ConfigStore` is.
/// Keyed by `BFRBBehavior.rawValue`, matching the client's
/// `DetectionAlertPreferencesStore.byBehavior` shape exactly so an exported
/// blob can be dropped in verbatim.
public actor AlertPrefsStore {
    private let url: URL
    private var cached: [String: NotificationPreferences]

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("alert-prefs.json")
        var seeded: [String: NotificationPreferences]
        // Missing or corrupt: same rule as ConfigStore — never throw out of
        // init over a file that hasn't been written yet or got truncated.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: NotificationPreferences].self, from: data) {
            seeded = decoded
        } else {
            seeded = [:]
        }
        // Every known behavior gets an entry, so `preferences(for:)` is a
        // pure lookup — mirrors the client's init-time seeding.
        for b in BFRBBehavior.allCases where seeded[b.rawValue] == nil {
            seeded[b.rawValue] = .default(for: b)
        }
        self.cached = seeded
    }

    public func load() -> [String: NotificationPreferences] { cached }

    public func preferences(for behavior: BFRBBehavior) -> NotificationPreferences {
        cached[behavior.rawValue] ?? .default(for: behavior)
    }

    public func save(_ prefs: [String: NotificationPreferences]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(prefs)
        // Atomic, same reasoning as ConfigStore's save.
        try data.write(to: url, options: .atomic)
        cached = prefs
    }
}
