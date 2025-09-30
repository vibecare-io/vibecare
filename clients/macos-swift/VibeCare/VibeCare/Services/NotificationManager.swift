import Foundation
@preconcurrency import UserNotifications
import Logging
import VCStubs

@MainActor
class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Published Properties
    @Published var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published var notificationSettings: UNNotificationSettings?

    // MARK: - Private Properties
    private let logger = Logger(label: "com.vibecare.notification-manager")
    private let notificationCenter = UNUserNotificationCenter.current()

    // Notification categories and actions
    private let scheduleTriggeredCategory = "SCHEDULE_TRIGGERED"
    private let viewRoutineAction = "VIEW_ROUTINE"
    private let dismissAction = "DISMISS"

    private override init() {
        super.init()
        setupNotificationCategories()
        notificationCenter.delegate = self
        Task {
            await checkPermissionStatus()
        }
    }

    // MARK: - Permission Management

    /// Request notification permissions from the user
    func requestPermissions() async -> Bool {
        logger.info("Requesting notification permissions")

        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])

            await checkPermissionStatus()

            if granted {
                logger.info("Notification permissions granted")
            } else {
                logger.warning("Notification permissions denied")
            }

            return granted
        } catch {
            logger.error("Failed to request notification permissions: \(error)")
            return false
        }
    }

    /// Check current notification permission status
    private func checkPermissionStatus() async {
        let settings = await notificationCenter.notificationSettings()

        await MainActor.run { [weak self] in
            self?.permissionStatus = settings.authorizationStatus
            self?.notificationSettings = settings
        }

        logger.info("Notification permission status: \(settings.authorizationStatus.rawValue)")
    }

    // MARK: - Notification Setup

    private func setupNotificationCategories() {
        // Define actions
        let viewRoutineAction = UNNotificationAction(
            identifier: viewRoutineAction,
            title: "View Routine",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: dismissAction,
            title: "Dismiss",
            options: []
        )

        // Define category for schedule triggered notifications
        let scheduleCategory = UNNotificationCategory(
            identifier: scheduleTriggeredCategory,
            actions: [viewRoutineAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        // Register categories
        notificationCenter.setNotificationCategories([scheduleCategory])

        logger.info("Notification categories configured")
    }

    // MARK: - Show Notifications

    /// Show notification for a triggered schedule
    func showScheduleNotification(for event: VCScheduleTriggeredEvent) async {
        guard permissionStatus == .authorized else {
            logger.warning("Cannot show notification - permissions not granted")
            return
        }

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "⏰ Schedule Triggered"
        content.subtitle = event.routineName

        // Format the scheduled time
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        let scheduledTime = event.hasScheduledTime ? event.scheduledTime.date : Date()

        content.body = "Scheduled for \(timeFormatter.string(from: scheduledTime))"
        content.sound = .default
        content.categoryIdentifier = scheduleTriggeredCategory

        // Add user info for handling actions
        content.userInfo = [
            "scheduleId": event.scheduleID,
            "routineId": event.routineID,
            "routineName": event.routineName
        ]

        // Create unique identifier
        let identifier = "schedule-\(event.scheduleID)-\(Date().timeIntervalSince1970)"

        // Create request
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        do {
            try await notificationCenter.add(request)
            logger.info("Schedule notification shown for: \(event.routineName)")
        } catch {
            logger.error("Failed to show schedule notification: \(error)")
        }
    }

    /// Show a generic notification
    func showNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = true) async {
        guard permissionStatus == .authorized else {
            logger.warning("Cannot show notification - permissions not granted")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        if sound {
            content.sound = .default
        }

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        do {
            try await notificationCenter.add(request)
            logger.info("Generic notification shown: \(title)")
        } catch {
            logger.error("Failed to show generic notification: \(error)")
        }
    }

    // MARK: - Badge Management

    /// Update app badge count
    func updateBadgeCount(_ count: Int) async {
        guard permissionStatus == .authorized else { return }

        do {
            try await notificationCenter.setBadgeCount(count)
            logger.info("Badge count updated to: \(count)")
        } catch {
            logger.error("Failed to update badge count: \(error)")
        }
    }

    /// Clear app badge
    func clearBadge() async {
        await updateBadgeCount(0)
    }

    // MARK: - Notification Management

    /// Remove all delivered notifications
    func removeAllDeliveredNotifications() {
        notificationCenter.removeAllDeliveredNotifications()
        logger.info("All delivered notifications removed")
    }

    /// Remove all pending notifications
    func removeAllPendingNotifications() {
        notificationCenter.removeAllPendingNotificationRequests()
        logger.info("All pending notifications removed")
    }

    /// Remove specific notification
    func removeNotification(withIdentifier identifier: String) {
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        logger.info("Notification removed: \(identifier)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            logger.info("Notification received in foreground: \(notification.request.identifier)")
        }

        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle notification action
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Task { @MainActor in
            logger.info("Notification action received: \(response.actionIdentifier)")

            switch response.actionIdentifier {
            case viewRoutineAction:
                // Handle view routine action
                if let routineId = userInfo["routineId"] as? String {
                    await handleViewRoutineAction(routineId: routineId)
                }

            case dismissAction, UNNotificationDismissActionIdentifier:
                // Notification was dismissed
                logger.info("Notification dismissed")

            case UNNotificationDefaultActionIdentifier:
                // User tapped on the notification
                if let routineId = userInfo["routineId"] as? String {
                    await handleViewRoutineAction(routineId: routineId)
                }

            default:
                break
            }
        }

        completionHandler()
    }

    // MARK: - Action Handlers

    private func handleViewRoutineAction(routineId: String) async {
        logger.info("Handling view routine action for: \(routineId)")

        // Post notification to open the routine
        NotificationCenter.default.post(
            name: Notification.Name("OpenRoutine"),
            object: nil,
            userInfo: ["routineId": routineId]
        )
    }
}

// MARK: - Authorization Status Extension

extension UNAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .denied:
            return "Denied"
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }
}