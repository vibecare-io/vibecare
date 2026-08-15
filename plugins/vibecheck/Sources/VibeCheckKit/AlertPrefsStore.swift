import Foundation
import VCPluginSDK

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
/// Field names and types match the client's property names on purpose, and
/// THIS encoding — plain `{"width":450,...}` — is the one that matters: it
/// is what rides on `VCAlert.appearance` and what the client's
/// `PluginAlertAppearance` decodes.
///
/// Correction to an earlier claim in this comment: these two types are NOT
/// byte-compatible, and an exported client blob canNOT be dropped in
/// verbatim. The client's version is `@Observable`, and that macro rewrites
/// its stored properties into an underscored backing store, so its
/// synthesized Codable emits
/// `{"_$observationRegistrar":{},"_width":450,...}` rather than
/// `{"width":450,...}`. Measured, not assumed — see
/// `theObservableTypesOwnEncodingIsNotTheWireSchema` in the client's
/// `PluginAlertAppearanceTests`. The client owns an explicit schema type for
/// the wire precisely so this asymmetry cannot bite again.
///
/// `CGFloat` fields become `Double` here — `CGFloat: Codable` encodes as a
/// single `Double` container, so that part of the shape is unchanged.
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

// MARK: - Persisted config -> wire appearance

/// The one place where vibecheck's persisted preferences become the SDK's
/// alert-appearance schema.
///
/// These two types are deliberately separate. `NotificationPreferences` is
/// this plugin's own config: it has an editor UI, an on-disk format in
/// `alert-prefs.json`, and defaults (`base`, `default(for:)`) that are
/// product decisions. `VCAlertAppearance` is the SDK's statement of what any
/// plugin may say about any alert. They line up field-for-field today only
/// because both were derived from the same client schema; keeping the
/// translation explicit means a future config field — a per-behavior sound,
/// say — can be added on one side without inventing a wire key on the other.
///
/// The enum translations are exhaustive `switch`es rather than
/// `init(rawValue:)` lookups on purpose. Raw-value matching would compile
/// forever and silently drop the field the day either enum grew a case the
/// other lacks; a `switch` makes that divergence a build error at exactly
/// the line that has to decide what to do about it.
extension NotificationPosition {
    var wire: VCAlertAppearance.Position {
        switch self {
        case .center: return .center
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
}

extension BlurIntensity {
    var wire: VCAlertAppearance.BlurIntensity {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}

extension NotificationPreferences {
    /// This behavior's stored look, expressed in the SDK's schema.
    ///
    /// Optionals pass through as optionals — `nil` stays `nil` so the SDK
    /// omits the key and the client applies its own default, rather than
    /// this plugin asserting a value the user never chose. The four
    /// non-optional stored properties (`position`, `moveable`,
    /// `screenBlurEnabled`, `screenBlurIntensity`) are always asserted,
    /// because this plugin genuinely does have an opinion about them:
    /// `AlertPrefsStore` seeds every behavior with `default(for:)`, so they
    /// always hold a real, user-visible value.
    ///
    /// `title`/`message` are forwarded exactly as stored, empty strings
    /// included. The client accepts but does not apply them (the alert's own
    /// title/body win), and `HostSink.fired` is what turns a stored title
    /// into the alert's actual title — so filtering them here would only
    /// change the bytes without changing anything a user can see.
    var wireAppearance: VCAlertAppearance {
        VCAlertAppearance(
            bundledIconId: bundledIconId,
            svgPath: svgPath,
            svgWidth: svgWidth,
            svgHeight: svgHeight,
            position: position.wire,
            width: width,
            height: height,
            moveable: moveable,
            autoDismissAfter: autoDismissAfter,
            screenBlurEnabled: screenBlurEnabled,
            screenBlurIntensity: screenBlurIntensity.wire,
            title: title,
            message: message
        )
    }
}

// MARK: - Store

/// Per-behavior alert preferences, file-backed the same way `ConfigStore` is.
/// Keyed by `BFRBBehavior.rawValue`, the same keying the client's
/// `DetectionAlertPreferencesStore.byBehavior` uses. (The per-behavior VALUES
/// are not interchangeable with that store's — see the type comment above.)
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
