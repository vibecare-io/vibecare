import Foundation
import Logging
import VibeNotify
import VCStubs

/// A button rendered on a notification — e.g. a plugin alert's "Snooze 10
/// min" / "Turn off" actions. Kept separate from `StandardNotification.Button`
/// (VibeNotify's own type) so callers like `PluginShellService` don't need
/// to import VibeNotify just to build one.
struct NotificationAction {
    let label: String
    let handler: () -> Void
}

@MainActor
class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Private Properties
    private let logger = Logger(label: "com.vibecare.notification-manager")
    private let policy = NotificationPolicy.shared

    private override init() {
        super.init()
        logger.info("NotificationManager initialized with VibeNotify")
    }

    // MARK: - Show Notifications

    /// Show notification for a triggered schedule using VibeNotify
    @discardableResult
    func showScheduleNotification(for event: VCScheduleTriggeredEvent) -> UUID? {
        logger.info("Showing schedule notification: \(event.scheduleName)")

        let scheduledTime = event.hasScheduledTime ? event.scheduledTime.date : Date()

        // Note: Notification preferences are now stored per-action, not at schedule level
        // For basic schedule notifications (without specific actions), use default preferences
        let notificationPreferences: NotificationPreferences? = nil

        let notificationID = VibeNotifyConfig.showScheduleNotification(
            scheduleName: event.scheduleName,
            routineName: event.routineName,
            scheduledTime: scheduledTime,
            notes: nil,
            preferences: notificationPreferences
        )

        if notificationID != nil {
            logger.info("Schedule notification displayed for: \(event.routineName)")
        } else {
            logger.info("Schedule notification blocked by policy")
        }
        return notificationID
    }

    /// Show a success notification
    @discardableResult
    func showSuccess(title: String = "Success", message: String) -> UUID? {
        logger.info("Showing success notification: \(title)")
        return VibeNotifyConfig.showSuccess(title: title, message: message)
    }

    /// Show an error notification
    @discardableResult
    func showError(title: String = "Error", message: String) -> UUID? {
        logger.error("Showing error notification: \(title) - \(message)")
        return VibeNotifyConfig.showError(title: title, message: message)
    }

    /// Show a warning notification, optionally with action buttons (e.g. a
    /// plugin alert's actions).
    @discardableResult
    func showWarning(title: String = "Warning", message: String, actions: [NotificationAction] = []) -> UUID? {
        logger.warning("Showing warning notification: \(title)")
        return VibeNotifyConfig.showWarning(title: title, message: message, actions: actions)
    }

    /// Show an info notification, optionally with action buttons (e.g. a
    /// plugin alert's actions).
    @discardableResult
    func showInfo(title: String = "Info", message: String, actions: [NotificationAction] = []) -> UUID? {
        logger.info("Showing info notification: \(title)")
        return VibeNotifyConfig.showInfo(title: title, message: message, actions: actions)
    }

    /// Show a quick toast notification
    @discardableResult
    func showToast(message: String, type: NotificationType = .info) -> UUID? {
        logger.info("Showing toast: \(message)")

        let icon: StandardNotification.IconType = switch type {
        case .success:
            .success
        case .error:
            .error
        case .warning:
            .warning
        case .info:
            .info
        case .schedule:
            .system("bell.fill")
        }

        return VibeNotifyConfig.showToast(message: message, icon: icon)
    }

    /// Generic notification method (backward compatibility)
    @discardableResult
    func showNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = true) -> UUID? {
        let message = subtitle != nil ? "\(subtitle!)\n\(body)" : body
        return showInfo(title: title, message: message)
    }

    // MARK: - Action Execution

    /// Execute a notification action from a schedule event
    @discardableResult
    func executeAction(_ action: Action, for event: VCScheduleTriggeredEvent) -> UUID? {
        guard action.type == .notification else {
            logger.error("Invalid action type for NotificationManager: \(action.type)")
            return nil
        }

        let title = action.parameters["title"] ?? event.scheduleName
        let body = action.parameters["body"] ?? "Scheduled: \(event.routineName)"
        let scheduledTime = event.hasScheduledTime ? event.scheduledTime.date : Date()

        // Deserialize notification preferences from action parameters
        let notificationPreferences = deserializeNotificationPreferences(from: action.parameters)

        let notificationID = VibeNotifyConfig.showScheduleNotification(
            scheduleName: title,
            routineName: body,
            scheduledTime: scheduledTime,
            notes: nil,
            preferences: notificationPreferences
        )

        if notificationID != nil {
            logger.info("Executed notification action: \(action.id)")
        } else {
            logger.info("Notification action blocked by policy: \(action.id)")
        }

        return notificationID
    }

    // MARK: - Helper Methods

    /// Deserialize notification preferences from action parameters
    private func deserializeNotificationPreferences(from params: [String: String]) -> NotificationPreferences? {
        // Create notification preferences from parameters
        // Only read svg_path (contains full URL for both bundled and custom icons)
        let svgPath = params["svg_path"]
        let svgWidth = params["svg_width"].flatMap { Double($0) }.map { CGFloat($0) }
        let svgHeight = params["svg_height"].flatMap { Double($0) }.map { CGFloat($0) }
        let title = params["title"]
        let message = params["body"]
        let position = params["position"].flatMap { NotificationPosition(rawValue: $0) } ?? .center
        let width = params["width"].flatMap { Double($0) }.map { CGFloat($0) }
        let height = params["height"].flatMap { Double($0) }.map { CGFloat($0) }
        let moveable = params["moveable"].flatMap { Bool($0) } ?? true
        let autoDismissAfter = params["auto_dismiss_after"].flatMap { Double($0) }
        let screenBlurEnabled = params["screen_blur_enabled"].flatMap { Bool($0) } ?? false
        let screenBlurIntensity = params["screen_blur_intensity"].flatMap { BlurIntensity(rawValue: $0) } ?? .medium

        // Only return preferences if at least some customization exists
        // Otherwise return nil to use default notification appearance
        if svgPath != nil || width != nil || height != nil || position != .center || screenBlurEnabled {
            return NotificationPreferences(
                bundledIconId: nil, // Always nil now - IDs converted to URLs
                svgPath: svgPath,
                svgWidth: svgWidth,
                svgHeight: svgHeight,
                title: title,
                message: message,
                position: position,
                width: width,
                height: height,
                moveable: moveable,
                autoDismissAfter: autoDismissAfter,
                screenBlurEnabled: screenBlurEnabled,
                screenBlurIntensity: screenBlurIntensity
            )
        }

        return nil
    }
}
