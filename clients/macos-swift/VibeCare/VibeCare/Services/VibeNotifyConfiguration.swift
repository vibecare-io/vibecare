import Foundation
import SwiftUI
import VibeNotify
import Logging

// MARK: - BlurIntensity to VibeNotify Conversion
extension BlurIntensity {
    /// Convert VibeCare BlurIntensity to VibeNotify ScreenBlurIntensity
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

  // MARK: - Logger

  private static let logger = Logger(label: "com.vibecare.vibe-notify-config")

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

    // Icon: SVG (url/file) if configured, else the caller's default system icon.
    if let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize {
      if svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://") {
        if let url = URL(string: svgPath) {
          builder = builder.svgURL(url, size: svgSize)
        } else {
          builder = builder.icon(.system(defaultSystemIcon))
        }
      } else {
        builder = builder.svg(svgPath, size: svgSize)
      }
    } else {
      builder = builder.icon(.system(defaultSystemIcon))
    }

    builder = builder
      .title(title)
      .message(message)
      .moveable(prefs.moveable)
      .alwaysOnTop(true)
      .dismissOnScreenTap(true)
      .autoDismiss(after: prefs.autoDismissAfter ?? quickDismissDelay)

    if prefs.screenBlurEnabled {
      builder = builder.screenBlur(true, intensity: prefs.screenBlurIntensity.vibeNotifyIntensity)
    }

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
    if let height = prefs.height {
      builder = builder.height(CGFloat(height))
    }

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

  // MARK: - VibeCheck Detection Alert

  /// Shows the notification for a confirmed BFRB detection, rendered through
  /// the same shared VibeNotify builder (`showNotification`) that schedule
  /// notifications use, customized via `DetectionAlertPreferencesStore`.
  ///
  /// Title/message fall back to the behavior's default label/nudge when the
  /// user hasn't customized them, and today's streak (e.g. "3rd nudge today")
  /// is always appended to the message.
  ///
  /// Priority is `.critical` so it always shows regardless of the global mute
  /// toggle — the detection sound and overlay flash already fire unconditionally.
  @MainActor
  @discardableResult
  static func showBFRBAlert(
    behavior: BFRBBehavior,
    count: Int,
    preferences: NotificationPreferences? = nil
  ) -> UUID? {
    // Swift default-parameter expressions can't reference another parameter
    // (e.g. `= DetectionAlertPreferencesStore.shared.preferences(for: behavior)`
    // is invalid because `behavior` isn't in scope there), so the default is
    // resolved here instead. Behavior is identical: omitting `preferences`
    // (as the sole caller, `VibeNotifyDetectionNotifier.notify`, does) still
    // looks up the store's per-behavior preferences.
    let prefs = preferences ?? DetectionAlertPreferencesStore.shared.preferences(for: behavior)
    let title = prefs.title?.nonEmpty ?? behavior.label
    let base = prefs.message?.nonEmpty ?? behavior.nudge
    let message = "\(base)\n\(ordinal(count)) nudge today"
    return showNotification(
      preferences: prefs,
      title: title,
      message: message,
      defaultSystemIcon: behavior.alertIcon,
      priority: .critical
    )
  }

  /// English ordinal for `n` (e.g. 1 -> "1st", 22 -> "22nd", 13 -> "13th").
  /// 11/12/13 are the special-case exceptions that take "th" despite ending in
  /// 1/2/3.
  static func ordinal(_ n: Int) -> String {
    let ones = n % 10
    let tens = n % 100
    let suffix: String
    if (11...13).contains(tens) {
      suffix = "th"
    } else {
      switch ones {
      case 1: suffix = "st"
      case 2: suffix = "nd"
      case 3: suffix = "rd"
      default: suffix = "th"
      }
    }
    return "\(n)\(suffix)"
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
