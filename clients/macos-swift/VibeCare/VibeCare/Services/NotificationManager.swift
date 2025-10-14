import Foundation
import Logging
import VibeNotify
import VCStubs

@MainActor
class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Private Properties
    private let logger = Logger(label: "com.vibecare.notification-manager")
    private let policy = NotificationPolicy.shared
    private let localStorage = ScheduleLocalStorage.shared

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

        // Try to fetch schedule from local storage to get custom notification preferences
        var notificationPreferences: NotificationPreferences? = nil
        do {
            if let schedule = try localStorage.getSchedule(id: event.scheduleID) {
                notificationPreferences = schedule.notificationPreferences
                logger.info("Using custom notification preferences for schedule: \(event.scheduleID)")
            }
        } catch {
            logger.error("Failed to fetch schedule for notification preferences: \(error)")
        }

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

    /// Show a warning notification
    @discardableResult
    func showWarning(title: String = "Warning", message: String) -> UUID? {
        logger.warning("Showing warning notification: \(title)")
        return VibeNotifyConfig.showWarning(title: title, message: message)
    }

    /// Show an info notification
    @discardableResult
    func showInfo(title: String = "Info", message: String) -> UUID? {
        logger.info("Showing info notification: \(title)")
        return VibeNotifyConfig.showInfo(title: title, message: message)
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
}
