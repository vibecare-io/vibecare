import Foundation

/// Priority level for notifications
enum NotificationPriority {
    case normal
    case critical
}

/// Centralized policy for controlling when notifications should be displayed
/// Provides simple enable/disable toggle with extensibility for future smart filtering
@MainActor
class NotificationPolicy: ObservableObject {
    static let shared = NotificationPolicy()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
        }
    }

    private init() {
        self.enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// Determine if a notification is allowed to be shown based on current policy
    /// - Parameter priority: Priority level of the notification (critical notifications always show)
    /// - Returns: true if notification should be displayed, false otherwise
    func isNotificationAllowed(priority: NotificationPriority = .normal) -> Bool {
        // Critical notifications always show, regardless of settings
        if priority == .critical {
            return true
        }

        // Check if notifications are globally disabled
        guard enabled else {
            return false
        }

        // TODO: Future enhancements
        // - Quiet hours: Check if current time is within user-defined quiet hours
        // - Meeting detection: Check if user is in a meeting (calendar integration)
        // - Screen sharing: Check if user is presenting/sharing screen
        // - Focus mode: Check system Focus/Do Not Disturb status
        // - Per-app rules: Allow/block based on frontmost application

        return true
    }

    /// Toggle notification enabled state
    func toggle() {
        enabled.toggle()
    }
}
