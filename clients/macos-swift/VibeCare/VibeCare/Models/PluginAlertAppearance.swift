import Foundation

/// The shell's public schema for `Alert.appearance` — the optional,
/// plugin-supplied presentation hints that ride on a single alert.
///
/// ## Why this is its own type
///
/// The obvious move is to decode the blob straight into
/// `NotificationPreferences`, which already has exactly these fields. It
/// does not work, and the reason is worth writing down so nobody
/// "simplifies" this away: `NotificationPreferences` is `@Observable`, and
/// that macro rewrites every stored property into an underscored backing
/// store. Its synthesized `Codable` therefore emits
/// `{"_$observationRegistrar":{},"_width":450,...}` — underscore-prefixed
/// keys plus the registrar — not `{"width":450,...}`. That round-trips
/// fine against itself (which is why the app's own persistence never
/// noticed) but it is not a schema any other process would ever write, and
/// it would silently change if the macro's implementation changed.
///
/// So the wire schema is declared here, explicitly, as a plain struct with
/// the field names plugins actually send. `NotificationPreferences` stays
/// what it is: an internal UI type.
///
/// ## Why this is not plugin-specific code
///
/// This describes the SHELL's alert vocabulary, not any one plugin's. Any
/// plugin may send it; a plugin that sends something else gets the default
/// alert rendering and needs no client change either way. The client still
/// knows nothing about what a given plugin does — only how it would like
/// its notification to look.
struct PluginAlertAppearance: Equatable, Sendable {
    var bundledIconId: String?
    /// Absolute (`http(s)://`, `file://`, `/abs/path`) or PLUGIN-RELATIVE.
    /// A relative path is resolved against the sending plugin's own mount
    /// (`/p/<id>/`) by `PluginShellService` — a plugin cannot know the port
    /// core assigned it, so a relative path is the only thing it can
    /// honestly send.
    var svgPath: String?
    var svgWidth: Double?
    var svgHeight: Double?
    var position: String?
    var width: Double?
    var height: Double?
    var moveable: Bool?
    var autoDismissAfter: TimeInterval?
    var screenBlurEnabled: Bool?
    var screenBlurIntensity: String?

    /// `title`/`message` are accepted so a plugin's stored preferences can
    /// be forwarded verbatim, but they are deliberately NOT applied to the
    /// rendered alert — see `preferences()`. The alert's own `title`/`body`
    /// always win, because the sender already applied its wording and may
    /// have added something computed at fire time (a running count, say)
    /// that these fields cannot contain.
    var title: String?
    var message: String?
}

extension PluginAlertAppearance: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundledIconId, svgPath, svgWidth, svgHeight, position, width, height
        case moveable, autoDismissAfter, screenBlurEnabled, screenBlurIntensity
        case title, message
    }

    private struct Unrecognised: Error {}

    /// Lenient per field, strict overall.
    ///
    /// Every field is decoded with `try?` so one bad value (a `width` sent
    /// as a string, an unknown `position`) costs that field and not the
    /// whole appearance — a partially-understood style is still closer to
    /// what the plugin asked for than no style at all.
    ///
    /// But a blob that matches NONE of these keys is rejected outright.
    /// Without that check, every optional field decodes to nil and any JSON
    /// object at all — including a completely different plugin's schema —
    /// would "successfully" decode into an all-nil appearance, which the
    /// renderer would then treat as a request to restyle the alert with
    /// nothing. `allKeys` reports only keys that map to a case above, so it
    /// is exactly the "did we understand any of this?" question.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard !c.allKeys.isEmpty else { throw Unrecognised() }

        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func number(_ key: CodingKeys) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil }

        bundledIconId = string(.bundledIconId)
        svgPath = string(.svgPath)
        svgWidth = number(.svgWidth)
        svgHeight = number(.svgHeight)
        position = string(.position)
        width = number(.width)
        height = number(.height)
        moveable = flag(.moveable)
        autoDismissAfter = number(.autoDismissAfter)
        screenBlurEnabled = flag(.screenBlurEnabled)
        screenBlurIntensity = string(.screenBlurIntensity)
        title = string(.title)
        message = string(.message)
    }
}

extension PluginAlertAppearance {
    /// Maps onto the shell's own notification preferences, filling anything
    /// the plugin left out from `NotificationPreferences.default` — the same
    /// baseline a schedule notification with no customization gets.
    ///
    /// `title`/`message` are intentionally left nil: the alert's own text is
    /// authoritative (see the properties' doc comment above), and putting
    /// them here would give a future renderer a second, staler source to
    /// pick from.
    func preferences() -> NotificationPreferences {
        let base = NotificationPreferences.default
        return NotificationPreferences(
            bundledIconId: bundledIconId,
            svgPath: svgPath,
            svgWidth: svgWidth.map { CGFloat($0) },
            svgHeight: svgHeight.map { CGFloat($0) },
            title: nil,
            message: nil,
            position: position.flatMap { NotificationPosition(rawValue: $0) } ?? base.position,
            width: width.map { CGFloat($0) } ?? base.width,
            height: height.map { CGFloat($0) } ?? base.height,
            moveable: moveable ?? base.moveable,
            autoDismissAfter: autoDismissAfter ?? base.autoDismissAfter,
            screenBlurEnabled: screenBlurEnabled ?? base.screenBlurEnabled,
            screenBlurIntensity: screenBlurIntensity.flatMap { BlurIntensity(rawValue: $0) } ?? base.screenBlurIntensity
        )
    }
}
