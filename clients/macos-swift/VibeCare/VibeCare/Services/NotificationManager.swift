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

        // Notification preferences are stored per-action, not at schedule
        // level. A bare schedule notification has no action to read, so it gets
        // the global layer alone — `nil` here, which
        // `VibeNotifyConfig.showScheduleNotification` resolves to
        // `GlobalNotificationSettings.current.basePreferences()`.
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

    /// Resolve an action's notification preferences: the user's global settings
    /// as defaults, with any appearance key the action sets winning over them.
    ///
    /// This used to build preferences purely from `params` and return `nil`
    /// unless *some* customisation existed — that `nil` is what made an
    /// uncustomised alert fall back to the hardcoded
    /// `NotificationPreferences.default`. Both halves are gone: the fallback is
    /// now the user's global settings, and the "is anything customised?" test
    /// is meaningless once every notification has preferences (they just may
    /// all come from the global layer). Hence the non-optional return.
    ///
    /// The rule itself lives in `GlobalNotificationSettings.resolving(actionParameters:)`
    /// so the action editor and this delivery path cannot disagree about it.
    private func deserializeNotificationPreferences(from params: [String: String]) -> NotificationPreferences {
        GlobalNotificationSettings.current.resolving(actionParameters: params)
    }
}
