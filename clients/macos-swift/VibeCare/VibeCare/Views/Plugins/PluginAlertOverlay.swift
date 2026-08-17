import AppKit
import SwiftUI
import VibeNotify

// MARK: - Presenter

/// Presents a plugin alert that carried an appearance (ruling U2) through
/// VibeNotify's rich renderer.
///
/// A client-owned SwiftUI view used to live here, because neither built-in
/// renderer could draw an illustration and buttons at the same time. The rich
/// renderer draws both, so the view is gone, and with it the hand-written
/// fifteen-argument window `Configuration`, the hand-rolled button style and the
/// `asyncAfter` that stood in for a countdown. Deleting the view is also how
/// this path *inherits* the contrast-correct text treatment rather than needing
/// it ported: the old view picked its colours from the system appearance alone —
/// a white glow under white text, a `.clear` shadow in light mode — which is the
/// bug the rich renderer exists to fix.
///
/// `.ambient`, not `.interrupt`, even when the appearance asked for blur: a
/// plugin alert is a positioned window whose geometry plugins author against,
/// and `.interrupt` deliberately ignores position and size in order to own the
/// whole screen. Legibility over an arbitrary desktop comes from the renderer's
/// local feathered scrim instead of a full-screen dim, which is what `.ambient`
/// is for. The consequence is that `PluginAlertPresentation.blurIntensity` no
/// longer reaches a window — `.ambient` builds no blur window at all.
@MainActor
enum PluginAlertPresenter {
    /// Presents the alert and returns its overlay id, or nil if notification
    /// policy suppressed it.
    @discardableResult
    static func show(
        presentation: PluginAlertPresentation,
        icon: NSImage?,
        title: String,
        message: String,
        actions: [NotificationAction],
        priority: NotificationPriority = .normal
    ) -> UUID? {
        guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
            return nil
        }

        let notification = RichNotification(
            // `.image`, never a URL. The icon arrives already fetched because
            // fetching goes through core's reverse proxy with a `vc_session`
            // cookie (`PluginShellService.resolveIcon`); handing VibeNotify a
            // URL would re-fetch it unauthenticated and fail.
            illustration: icon.map { .image($0, size: presentation.iconSize) },
            title: title,
            message: message,
            buttons: actions.map { action in
                // `.secondary` so the library cancels the dismiss clock and then
                // takes the window down after running the handler. The handler
                // is a fire-and-forget HTTP call
                // (`PluginShellService.performAction`), so waiting on it would
                // leave the alert up for a round trip with no feedback.
                StandardNotification.Button(
                    title: action.label, style: .secondary, action: action.handler)
            },
            // The clock owns the alert's lifetime now, which the `asyncAfter`
            // this replaces never could: an early dismissal cancels it instead
            // of leaving a timer to fire into a window that is already gone.
            // `.none` because the alert this reproduces showed no countdown.
            autoDismiss: .init(delay: presentation.autoDismissAfter, indicator: .none),
            mode: .ambient
        )

        // The appearance's height is a floor, and in the rich renderer it is a
        // floor well below what the content occupies — `richAmbientHeight`
        // carries the measurements and the reasoning, and lives next to the
        // schedule path because both feed the same renderer and the metrics
        // being mirrored are one renderer's.
        let height = fittingHeight(
            for: RichNotificationView(notification: notification, onDismiss: {}),
            width: presentation.width,
            atLeast: max(
                presentation.minHeight,
                VibeNotifyConfig.richAmbientHeight(
                    illustrationHeight: icon == nil ? 0 : presentation.iconSize.height,
                    hasButtons: !actions.isEmpty
                )
            )
        )

        return VibeNotify.shared.showRich(
            notification,
            configuration: .ambient(
                position: windowPosition(for: presentation.position),
                width: presentation.width,
                height: height,
                dismissOnScreenTap: true
            )
        )
    }

    /// The height the content actually needs at this width, floored at the
    /// appearance's configured height.
    ///
    /// Measured rather than assumed because the appearance was authored for
    /// an alert with no buttons: reusing its height verbatim would push the
    /// button row past the bottom of a borderless window, where it is not
    /// merely ugly but unclickable — and the button in question is "Turn
    /// off". `fittingSize` can report zero for content SwiftUI cannot size
    /// eagerly, so a zero measurement falls back to the configured height.
    ///
    /// `RichNotificationView` is one such view, deliberately: its
    /// `GeometryReader` exists precisely so the hosted content publishes no
    /// height of its own and cannot resize the window it was given. Measured
    /// through this probe it reports 10pt, so today the floor always wins and
    /// `VibeNotifyConfig.richAmbientHeight` is what decides the window. This
    /// stays the way in for a renderer that ever does report a real size.
    private static func fittingHeight(
        for view: some View, width: CGFloat, atLeast minimum: CGFloat
    ) -> CGFloat {
        let probe = NSHostingView(rootView: AnyView(view.frame(width: width)))
        let measured = probe.fittingSize.height
        guard measured > 0 else { return minimum }
        return max(minimum, measured)
    }

    private static func windowPosition(
        for position: NotificationPosition
    ) -> OverlayWindowManager.WindowPosition {
        switch position {
        case .center: return .center
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }
}
