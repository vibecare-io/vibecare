import CoreGraphics
import Foundation

/// Which renderer a plugin alert gets.
enum PluginAlertRoute: Equatable {
    /// VibeNotify's standard banner (`showWarning`/`showInfo`) — what every
    /// plugin alert got before appearances existed. Draws action buttons,
    /// draws no illustration.
    case plain
    /// The shell's own overlay: full-size illustration, title, message and
    /// action buttons, positioned and blurred per the appearance.
    case rich
}

/// The window geometry and timing a rich plugin alert is presented with,
/// derived from an appearance blob.
///
/// Extracted as a plain value, separate from the SwiftUI view and from
/// AppKit, for one reason: it is the part of "does the alert look right"
/// that can be asserted without a screen. Everything here — the illustration
/// staying full-size, blur only when asked for, an alert that actually
/// dismisses — is otherwise only checkable by eye.
///
/// Defaults are the ones the old in-app VibeCheck alert used
/// (`DetectionAlertPreferencesStore.makeDefault`), because that is the
/// design this reproduces. They apply to ANY plugin: a plugin that sends a
/// partial appearance gets sensible proportions rather than a zero-sized
/// icon or an alert that never goes away.
struct PluginAlertPresentation: Equatable {
    var position: NotificationPosition
    var width: CGFloat
    /// A FLOOR, not a fixed height. The appearance was authored for an alert
    /// with no buttons; the presenter measures the view's fitting height and
    /// takes whichever is larger, so adding a button row cannot clip the
    /// message off the bottom.
    var minHeight: CGFloat
    var iconSize: CGSize
    /// `nil` means no screen blur at all — distinct from "blur at the
    /// lightest setting". The appearance carries an intensity even when blur
    /// is off, so this must be gated on `screenBlurEnabled` rather than read
    /// straight through.
    var blurIntensity: BlurIntensity?
    var autoDismissAfter: TimeInterval
    var moveable: Bool

    /// The old design's proportions, used for anything the appearance omits.
    static let defaultWidth: CGFloat = 450
    static let defaultHeight: CGFloat = 220
    static let defaultIconSize = CGSize(width: 220, height: 150)
    static let defaultDismissAfter: TimeInterval = 20

    init(preferences p: NotificationPreferences) {
        position = p.position
        width = p.width ?? Self.defaultWidth
        minHeight = p.height ?? Self.defaultHeight
        iconSize = CGSize(
            width: p.svgWidth ?? Self.defaultIconSize.width,
            height: p.svgHeight ?? Self.defaultIconSize.height
        )
        blurIntensity = p.screenBlurEnabled ? p.screenBlurIntensity : nil
        autoDismissAfter = p.autoDismissAfter ?? Self.defaultDismissAfter
        moveable = p.moveable
    }

    /// Decides which renderer an alert gets.
    ///
    /// The interesting case is the third: an appearance that ASKED for an
    /// illustration and did not get one falls back to the banner rather than
    /// rendering a rich alert with a hole where the picture should be. A
    /// missing illustration is a cosmetic loss; the banner still carries the
    /// action buttons, and losing the "Turn off" button — the user's way to
    /// stop a camera they want stopped — would be a functional one.
    ///
    /// An appearance that never asked for an illustration is NOT that case.
    /// Position, size and blur are styling in their own right, and a plugin
    /// that styles its alerts without an icon still gets what it asked for.
    static func route(preferences: NotificationPreferences?, iconLoaded: Bool) -> PluginAlertRoute {
        guard let preferences else { return .plain }
        guard preferences.svgPath != nil else { return .rich }
        return iconLoaded ? .rich : .plain
    }
}
