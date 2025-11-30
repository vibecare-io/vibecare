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
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

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

    // Start building notification
    var builder = VibeNotify.builder()

    // Add SVG if specified (prioritizes bundled icon, falls back to custom path)
    if let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize {
      logger.debug("🔍 showScheduleNotification - SVG icon will be used", metadata: [
        "svgPath": "\(svgPath)",
        "svgSize": "\(svgSize)"
      ])

      // Check if it's a URL (http/https) or local file path
      if svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://") {
        // Remote URL - use .svgURL() method
        if let url = URL(string: svgPath) {
          logger.debug("🔍 showScheduleNotification - Using .svgURL() for remote icon")
          builder = builder.svgURL(url, size: svgSize)
        } else {
          logger.warning("🔍 showScheduleNotification - Invalid URL, falling back to system icon", metadata: ["svgPath": "\(svgPath)"])
          builder = builder.icon(.system("bell.badge.fill"))
        }
      } else {
        // Local file path - use .svg() method
        logger.debug("🔍 showScheduleNotification - Using .svg() for local file")
        builder = builder.svg(svgPath, size: svgSize)
      }
    } else {
      logger.debug("🔍 showScheduleNotification - Fallback to system icon", metadata: [
        "svgPath": "\(prefs.resolvedSVGPath == nil ? "nil" : "exists")",
        "svgSize": "\(prefs.svgSize == nil ? "nil" : "exists")"
      ])
      // Fallback to system icon
      builder = builder.icon(.system("bell.badge.fill"))
    }

    // Apply customizations
    builder = builder
      .title(title)
      .message(message)
      .moveable(prefs.moveable)
      .alwaysOnTop(true)
      .dismissOnScreenTap(true)
      .autoDismiss(after: prefs.autoDismissAfter ?? quickDismissDelay)

    // Apply screen blur if enabled with intensity
    if prefs.screenBlurEnabled {
      builder = builder.screenBlur(true, intensity: prefs.screenBlurIntensity.vibeNotifyIntensity)
    }

    // Set position based on preference
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

    // Apply width and height if specified
    if let width = prefs.width {
      builder = builder.width(CGFloat(width))
    }
    if let height = prefs.height {
      builder = builder.height(CGFloat(height))
    }

    logger.debug("🔍 showScheduleNotification - Calling builder.show()")
    let notificationId = builder.show()
    logger.debug("🔍 showScheduleNotification - END", metadata: ["notificationId": "\(notificationId.uuidString)"])
    return Optional(notificationId)
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
  static func showWarning(title: String = "Warning", message: String, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.warning)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: defaultDismissDelay, showProgress: true)
      .show()
  }

  @MainActor
  @discardableResult
  static func showInfo(title: String = "Info", message: String, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.info)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: quickDismissDelay, showProgress: true)
      .show()
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
