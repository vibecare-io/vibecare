import AppKit
import SwiftUI
import VibeNotify

/// The shell's own rendering of a plugin alert that carried an appearance
/// (ruling U2).
///
/// ## Why this view exists at all
///
/// VibeNotify 0.0.5 has two built-in renderers and neither can draw an
/// illustration and buttons at the same time:
///
/// * `SVGNotificationView` draws a full-size SVG, and `SVGNotification` has
///   no `buttons` property — the builder's buttons are dropped on the way in.
/// * `StandardNotificationView` draws buttons, but renders
///   `IconType.svg`/`.url` as `EmptyView()` and pins `IconType.image` to a
///   hardcoded 48x48 frame.
///
/// The package's third path — a caller-supplied SwiftUI view rendered in the
/// same overlay window machinery — has neither limitation, so the layout
/// lives here instead. It is deliberately modelled on `SVGNotificationView`
/// (the "old and nice" design): illustration at full size, no card chrome,
/// floating over the blurred screen, adaptive text with a glow in dark mode.
/// The button row is the one addition.
///
/// ## Why it is not plugin-specific
///
/// Nothing here names a plugin or knows what any alert means. It renders the
/// shell's own appearance vocabulary (`PluginAlertPresentation`), which any
/// plugin may send. That is the rule that lets a plugin ship a styled alert
/// without a client release.
struct PluginAlertOverlayView: View {
    let icon: NSImage?
    let iconSize: CGSize
    let title: String
    let message: String
    let actions: [NotificationAction]
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0.0

    /// Follows the system theme, exactly as `SVGNotificationView` does: the
    /// alert floats over a blurred desktop with no background of its own, so
    /// the text needs a glow to stay legible against whatever is behind it.
    private var useLightText: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 20) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize.width, height: iconSize.height)
                    .shadow(color: useLightText ? .white.opacity(0.5) : .black.opacity(0.5), radius: 15)
            }

            if !title.isEmpty {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(useLightText ? .white : .primary)
                    .shadow(color: useLightText ? .white.opacity(0.3) : .clear, radius: 4)
                    .multilineTextAlignment(.center)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.body)
                    .foregroundColor(useLightText ? .white.opacity(0.9) : .secondary)
                    .shadow(color: useLightText ? .white.opacity(0.2) : .clear, radius: 3)
                    .multilineTextAlignment(.center)
            }

            if !actions.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        SwiftUI.Button {
                            // Run the action, then take the alert down. The
                            // action itself is a fire-and-forget HTTP call
                            // (see PluginShellService.performAction), so
                            // waiting for it would leave the alert on screen
                            // for a round trip with no feedback.
                            action.handler()
                            onDismiss()
                        } label: {
                            Text(action.label)
                                .fontWeight(.medium)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(PluginAlertButtonStyle())
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(24)
        // The whole card is a hit target for dismissal EXCEPT the buttons,
        // which take their taps first. Without `contentShape` the transparent
        // padding around the content would not respond at all.
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                scale = 1.0
                opacity = 1.0
            }
        }
        .scaleEffect(scale)
        .opacity(opacity)
    }
}

/// A button legible against a blurred desktop. VibeNotify's own
/// `SecondaryButtonStyle` is internal to that package, and a plain
/// `.bordered` button disappears against a light-blurred background, so the
/// style is owned here.
private struct PluginAlertButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .foregroundColor(.primary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Presenter

/// Shows `PluginAlertOverlayView` in VibeNotify's overlay window.
///
/// This goes through `OverlayWindowManager.show(id:configuration:content:)`
/// rather than `VibeNotify.showCustom(...)`. They are the same mechanism —
/// `showCustom` is a four-argument wrapper around this exact call — but
/// `showCustom` hardcodes the rest of the `Configuration`, and the three
/// things it drops are the three this alert needs most: `screenBlur` (with
/// its separate full-screen blur window), `position`, and `width`/`height`.
/// Rebuilding full-screen blur inside the view is not equivalent: a material
/// in the view's own background blurs only what is behind the 450x220 window,
/// whereas the old design dimmed the entire screen. Using the underlying
/// public method keeps that behaviour identical to the old alert instead of
/// approximating it.
///
/// Auto-dismiss IS ours to schedule: the built-in renderers each run their
/// own timer, and a caller-supplied view gets none.
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

        let id = UUID()
        let view = PluginAlertOverlayView(
            icon: icon,
            iconSize: presentation.iconSize,
            title: title,
            message: message,
            actions: actions,
            onDismiss: { OverlayWindowManager.shared.dismiss(id: id) }
        )

        let height = fittingHeight(for: view, width: presentation.width, atLeast: presentation.minHeight)

        let configuration = OverlayWindowManager.Configuration(
            // Position + explicit width/height override the presentation
            // mode entirely (see OverlayWindowManager.createWindow), so this
            // is only a starting rect.
            presentationMode: .fullScreen,
            position: windowPosition(for: presentation.position),
            width: presentation.width,
            height: height,
            windowLevel: .floating,
            backgroundColor: .clear,
            isTransparent: true,
            ignoresMouseEvents: false,
            isMoveable: presentation.moveable,
            alwaysOnTop: true,
            // No window material: the design floats over the blurred screen
            // with no card behind it, same as the alert this replaces.
            transparent: false,
            screenBlur: presentation.blurIntensity != nil,
            screenBlurIntensity: presentation.blurIntensity?.vibeNotifyIntensity,
            dismissOnScreenTap: true,
            animatePresentation: true
        )

        OverlayWindowManager.shared.show(id: id, configuration: configuration) { view }

        // Dismissing an already-dismissed id is a no-op inside
        // OverlayWindowManager (it looks the window up first), so a button
        // press that beats the timer needs no cancellation here.
        DispatchQueue.main.asyncAfter(deadline: .now() + presentation.autoDismissAfter) {
            OverlayWindowManager.shared.dismiss(id: id)
        }
        return id
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
