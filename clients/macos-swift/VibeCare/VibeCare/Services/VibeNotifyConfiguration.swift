import Foundation
import SwiftUI
import VibeNotify
import Logging

// MARK: - BlurIntensity to VibeNotify Conversion
extension BlurIntensity {
    /// Convert VibeCare BlurIntensity to VibeNotify ScreenBlurIntensity.
    ///
    /// One of the three type-translation boundaries between VibeCare's own
    /// vocabulary and VibeNotify's. Currently uncalled: both alert paths now
    /// pick an `AlertMode`, and its factories own the backdrop — `.interrupt`
    /// blurs heavily and dims to `Legibility.safeDim`, `.ambient` does not blur
    /// at all. Kept because the boundary, not the call site, is the thing worth
    /// preserving: it is where an intensity preference reconnects to a window
    /// if the library ever exposes an intensity-taking mode.
    var vibeNotifyIntensity: ScreenBlurIntensity {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}

private extension String {
  var nonEmpty: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}

/// Centralized configuration for VibeNotify notifications
/// Provides consistent styling and helper methods for VibeCare notifications
enum VibeNotifyConfig {

  // MARK: - Brand Colors

  static let brandAccentColor = Color.accentColor

  // MARK: - Default Settings

  static let defaultDismissDelay: TimeInterval = 8.0
  static let quickDismissDelay: TimeInterval = 3.0
  static let defaultBannerHeight: CGFloat = 120
  static let compactBannerHeight: CGFloat = 80
  /// The SF Symbol size a schedule with no configured SVG falls back to. Large
  /// enough to read as the alert's illustration rather than a decoration, and
  /// scaled down by `Illustration.fitted(in:)` if the window is too small for
  /// it.
  static let fallbackSymbolPointSize: CGFloat = 56

  // MARK: - Logger

  private static let logger = Logger(label: "com.vibecare.vibe-notify-config")

  // MARK: - Ambient Window Height

  /// The window height an `.ambient` rich alert needs, which is not the height
  /// the user — or a plugin appearance — authored.
  ///
  /// `.interrupt` needs no such calculation; it *is* the screen. `.ambient` is a
  /// fixed-size window, and the rich renderer clips content that does not fit
  /// rather than growing the window — deliberately, because an
  /// `NSHostingView` free to publish its content's height resized an `.ambient`
  /// window to 2289pt tall. Every authored height in this app predates that
  /// renderer: they were chosen against one with no 28pt content padding, no
  /// 26pt title and no half-height illustration cap. At the default 450x220 the
  /// rich renderer clips its own illustration at the top and everything below
  /// the message at the bottom. So an authored height is a floor, not a size.
  ///
  /// Erring high is close to free: the window is fully transparent and the
  /// content is centred in it, so the only consequences are a larger
  /// click-to-dismiss area and, at a corner position, content sitting a little
  /// further from the corner. Erring low costs a button nobody can click.
  ///
  /// `min(illustrationHeight, chrome)` is the renderer's own rule rather than a
  /// guess: `RichNotification.Illustration.fitted(in:)` scales an illustration
  /// taller than half the window down to fit, so past `chrome` the window stops
  /// growing with the picture and settles at twice the chrome.
  ///
  /// Calibrated by rendering `RichNotificationView` — with a live
  /// `NotificationClock` in its environment, since the clock's own row costs
  /// height — at scale 1, and finding the smallest height at which no ink
  /// touches the frame edge. Over illustration heights of 56/150/200/300pt,
  /// messages of one to five lines, and widths of 300/350/450pt, the worst cases
  /// were 248pt of chrome without a button row and 286pt with one. Both worst
  /// cases are a five-line message, which is not hypothetical: it is what the
  /// customization sheet's preview substitutes when no message is set.
  static func richAmbientHeight(illustrationHeight: CGFloat, hasButtons: Bool) -> CGFloat {
    let chrome = hasButtons ? richChromeWithButtons : richChrome
    return chrome + min(illustrationHeight, chrome)
  }

  /// Room for everything the rich renderer draws that is not the illustration:
  /// 28pt of padding top and bottom, a 26pt title, the message, 22pt between
  /// each element, and the dismiss clock's own row. Measured worst case 248 (see
  /// above); the margin is for a message longer than any measured.
  private static let richChrome: CGFloat = 264
  /// `richChrome` with a row of action buttons — measured worst case 286.
  private static let richChromeWithButtons: CGFloat = 304

  // MARK: - Schedule Notification

  @MainActor
  @discardableResult
  static func showScheduleNotification(
    scheduleName: String,
    routineName: String,
    scheduledTime: Date,
    notes: String? = nil,
    priority: NotificationPriority = .normal,
    preferences: NotificationPreferences? = nil
  ) -> UUID? {
    // Use custom preferences or default
    let prefs = preferences ?? .default

    logger.debug("🔍 showScheduleNotification - START", metadata: [
      "svgPath": "\(prefs.svgPath ?? "nil")",
      "svgWidth": "\(prefs.svgWidth?.description ?? "nil")",
      "svgHeight": "\(prefs.svgHeight?.description ?? "nil")",
      "svgSize": "\(prefs.svgSize?.debugDescription ?? "nil")",
      "resolvedSVGPath": "\(prefs.resolvedSVGPath ?? "nil")"
    ])

    // Format title and message using preferences
    let title = prefs.formatTitle(scheduleName: scheduleName, routineName: routineName)
    let message = prefs.formatMessage(
      scheduleName: scheduleName,
      routineName: routineName,
      scheduledTime: scheduledTime
    )

    let notificationId = showNotification(
      preferences: prefs,
      title: title,
      message: message,
      defaultSystemIcon: "bell.badge.fill",
      priority: priority
    )
    logger.debug("🔍 showScheduleNotification - END", metadata: ["notificationId": "\(notificationId?.uuidString ?? "nil")"])
    return notificationId
  }

  // MARK: - Shared Notification Renderer

  /// The shared VibeNotify builder core used by both schedule notifications
  /// and the VibeCheck detection alert. Takes already-resolved `title`/`message`
  /// and a `defaultSystemIcon` fallback for when no SVG icon is configured.
  @MainActor
  @discardableResult
  private static func showNotification(
    preferences prefs: NotificationPreferences,
    title: String,
    message: String,
    defaultSystemIcon: String,
    priority: NotificationPriority
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    var builder = VibeNotify.builder()

    // Illustration: SVG (url/file) if configured, else the caller's default
    // system icon as an SF Symbol. Deliberately `.illustration(.symbol(...))`
    // rather than `.icon(.system(...))`: the latter is a
    // `StandardNotification.IconType`, which the rich renderer's routing does
    // not recognise as an illustration at all, so the no-SVG case — what every
    // unconfigured schedule gets — would render without a picture. A nil
    // `color` means "the title colour", i.e. whatever is legible over the
    // scrim the renderer drew.
    if let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize {
      if svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://") {
        if let url = URL(string: svgPath) {
          builder = builder.svgURL(url, size: svgSize)
        } else {
          builder = builder.illustration(.symbol(defaultSystemIcon, pointSize: fallbackSymbolPointSize, color: nil))
        }
      } else {
        builder = builder.svg(svgPath, size: svgSize)
      }
    } else {
      builder = builder.illustration(.symbol(defaultSystemIcon, pointSize: fallbackSymbolPointSize, color: nil))
    }

    builder = builder
      .title(title)
      .message(message)
      .dismissOnScreenTap(true)
      .autoDismiss(after: prefs.autoDismissAfter ?? quickDismissDelay)
      // The blur toggle is already the user's way of saying "take over my
      // screen for this", so it selects the alert mode rather than a lone
      // window knob — no new persisted key and no new control in the
      // customization UI. `.interrupt` dims the whole screen to
      // `Legibility.safeDim` and picks text colours against that dim; the old
      // code pinned a light blur at 0.1 and chose text from the system
      // appearance, which is exactly how a title landed invisible over a dark
      // terminal.
      //
      // Setting `.mode(_:)` at all is what routes this funnel to the rich
      // renderer (see `NotificationBuilder.routesToRichRenderer`), which is
      // also why `.moveable`, `.alwaysOnTop` and `.screenBlur(_:intensity:)`
      // are gone from this chain: `AlertMode`'s factories own the whole
      // window `Configuration` now, and leaving inert builder calls here
      // would read as though the preferences still reached the window.
      // `prefs.screenBlurIntensity` and `prefs.moveable` are consequently no
      // longer honoured for schedule alerts.
      .mode(prefs.screenBlurEnabled ? .interrupt : .ambient)

    switch prefs.position {
    case .center:
      builder = builder.position(.center)
    case .topLeft:
      builder = builder.position(.topLeft)
    case .topRight:
      builder = builder.position(.topRight)
    case .bottomLeft:
      builder = builder.position(.bottomLeft)
    case .bottomRight:
      builder = builder.position(.bottomRight)
    }

    if let width = prefs.width {
      builder = builder.width(CGFloat(width))
    }
    // The authored height is a floor — see `richAmbientHeight`. Unconditional
    // rather than branched on the mode because `.interrupt` ignores width and
    // height entirely (it takes the whole screen), so there is nothing for a
    // branch to protect. A schedule alert carries no action buttons; its Done /
    // Snooze row is a later task.
    builder = builder.height(
      max(
        CGFloat(prefs.height ?? 0),
        richAmbientHeight(
          // The height of the picture as the renderer will be asked to draw it.
          // The invalid-URL branch above falls back to a symbol while `svgSize`
          // is still set, so that one case reserves the SVG's room for a smaller
          // symbol — over-reserving, which is the harmless direction.
          illustrationHeight: prefs.svgSize?.height ?? fallbackSymbolPointSize,
          hasButtons: false
        )
      )
    )

    return builder.show()
  }

  // MARK: - Position Mapping
  // Note: The position is set using the builder's .position() method
  // which accepts the enum directly (e.g., .center, .topLeft, etc.)

  // MARK: - Generic Notification Methods

  @MainActor
  @discardableResult
  static func showSuccess(title: String = "Success", message: String, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.success)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: quickDismissDelay, showProgress: true)
      .show()
  }

  @MainActor
  @discardableResult
  static func showError(title: String = "Error", message: String, priority: NotificationPriority = .critical) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.error)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: defaultDismissDelay, showProgress: true)
      .show()
  }

  @MainActor
  @discardableResult
  static func showWarning(
    title: String = "Warning",
    message: String,
    priority: NotificationPriority = .normal,
    actions: [NotificationAction] = []
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    var builder = VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.warning)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: defaultDismissDelay, showProgress: true)
    for action in actions {
      builder = builder.button(StandardNotification.Button(title: action.label, style: .secondary, action: action.handler))
    }
    return builder.show()
  }

  @MainActor
  @discardableResult
  static func showInfo(
    title: String = "Info",
    message: String,
    priority: NotificationPriority = .normal,
    actions: [NotificationAction] = []
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    var builder = VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.info)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: quickDismissDelay, showProgress: true)
    for action in actions {
      builder = builder.button(StandardNotification.Button(title: action.label, style: .secondary, action: action.handler))
    }
    return builder.show()
  }

  // MARK: - Toast Notifications (Quick Updates)

  @MainActor
  @discardableResult
  static func showToast(message: String, icon: StandardNotification.IconType = .info, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .message(message)
      .icon(icon)
      .presentationMode(.toast(corner: .topRight, size: CGSize(width: 300, height: 100)))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: 2.0, showProgress: false)
      .show()
  }

}

// MARK: - Notification Type Enum

enum NotificationType {
  case success
  case error
  case warning
  case info
  case schedule
}
