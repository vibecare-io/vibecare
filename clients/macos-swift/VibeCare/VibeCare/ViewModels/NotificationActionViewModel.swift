import Foundation
import SwiftUI
import Logging

/// ViewModel for managing notification action state using Swift's Observation framework
/// This replaces the callback-based pattern with a centralized observable state
@Observable
final class NotificationActionViewModel {
    var preferences: NotificationPreferences
    var parameters: [String: String]
    /// Whether this action pins its own appearance instead of inheriting the
    /// global notification settings. See `ScheduleActionCard.overridesAppearance`
    /// for why this is derived from the parameters rather than stored beside
    /// them.
    var overridesAppearance: Bool

    private let logger = Logger(label: "com.vibecare.notification-action-vm")

    init(
        preferences: NotificationPreferences,
        parameters: [String: String],
        overridesAppearance: Bool? = nil
    ) {
        self.preferences = preferences
        self.parameters = parameters
        self.overridesAppearance =
            overridesAppearance ?? GlobalNotificationSettings.overridesAppearance(parameters)
    }

    /// Turns the per-action override on or off.
    ///
    /// Switching it **off** re-seeds the appearance fields from the global
    /// settings, so the (now read-only-in-effect) controls stop showing values
    /// that no longer apply. Content — icon, title, message, break duration —
    /// is untouched either way; it has no global counterpart.
    func setOverridesAppearance(_ overrides: Bool) {
        overridesAppearance = overrides
        guard !overrides else { return }

        let global = GlobalNotificationSettings.current
        preferences.position = global.position
        preferences.width = global.width
        preferences.height = global.height
        preferences.moveable = global.moveable
        preferences.autoDismissAfter = global.autoDismissAfter
        preferences.screenBlurEnabled = global.screenBlurEnabled
        preferences.screenBlurIntensity = global.screenBlurIntensity
    }

    // MARK: - Convenience Update Methods

    /// Update the SVG icon URL and set default dimensions if needed
    func updateIconURL(_ url: String) {
        logger.debug("🔍 updateIconURL - Received URL", metadata: [
            "url": "\(url)",
            "before.svgPath": "\(preferences.svgPath ?? "nil")",
            "before.objectId": "\(ObjectIdentifier(preferences))"
        ])

        // Direct mutation works now because NotificationPreferences is @Observable
        preferences.svgPath = url
        preferences.svgWidth = preferences.svgWidth ?? 350
        preferences.svgHeight = preferences.svgHeight ?? 320

        logger.debug("🔍 updateIconURL - Updated preferences", metadata: [
            "after.svgPath": "\(preferences.svgPath ?? "nil")",
            "after.svgWidth": "\(preferences.svgWidth?.description ?? "nil")",
            "after.svgHeight": "\(preferences.svgHeight?.description ?? "nil")",
            "after.objectId": "\(ObjectIdentifier(preferences))"
        ])
    }

    /// Update the notification title (nil if empty)
    func updateTitle(_ title: String) {
        preferences.title = title.isEmpty ? nil : title
    }

    /// Update the notification message (nil if empty)
    func updateMessage(_ message: String) {
        preferences.message = message.isEmpty ? nil : message
    }

    /// Remove the current SVG icon
    func removeIcon() {
        preferences.svgPath = nil
        preferences.svgWidth = nil
        preferences.svgHeight = nil
    }

    /// Update SVG icon dimensions
    func updateIconSize(width: CGFloat, height: CGFloat) {
        preferences.svgWidth = width
        preferences.svgHeight = height
    }

    /// Reset preferences to the user's global notification settings
    func resetToDefault() {
        preferences = GlobalNotificationSettings.current.basePreferences()
        overridesAppearance = false
    }

    /// Apply a preset configuration. A preset is entirely appearance, so
    /// picking one *is* the decision to override the global settings.
    func applyPreset(_ preset: NotificationPreferences) {
        preferences = preset.copy()
        overridesAppearance = true
    }

    // MARK: - Serialization

    /// Serialize current preferences to parameters dictionary for API storage
    func serializeToParameters() {
        logger.debug("🔍 serializeToParameters - START", metadata: [
            "preferences.svgPath": "\(preferences.svgPath ?? "nil")"
        ])

        // Serialize SVG icon path and dimensions
        if let svgPath = preferences.svgPath {
            parameters["svg_path"] = svgPath
            logger.debug("🔍 serializeToParameters - Set svg_path parameter", metadata: ["svg_path": "\(svgPath)"])
        } else {
            parameters.removeValue(forKey: "svg_path")
            logger.debug("🔍 serializeToParameters - Removed svg_path parameter (was nil)")
        }

        if let svgWidth = preferences.svgWidth {
            parameters["svg_width"] = String(Double(svgWidth))
        }
        if let svgHeight = preferences.svgHeight {
            parameters["svg_height"] = String(Double(svgHeight))
        }

        // Serialize title and body (only if set)
        if let title = preferences.title, !title.isEmpty {
            parameters["title"] = title
        }
        if let message = preferences.message, !message.isEmpty {
            parameters["body"] = message
        }

        // Ensure required fields exist
        if parameters["title"] == nil {
            parameters["title"] = ""
        }
        if parameters["body"] == nil {
            parameters["body"] = ""
        }

        // Serialize the break countdown's duration. Content, not appearance:
        // whether an action runs a break is what the action *is*, and only its
        // wording comes from the global settings.
        if let taskTimerSeconds = preferences.taskTimerSeconds {
            parameters["task_timer_seconds"] = String(taskTimerSeconds)
        } else {
            parameters.removeValue(forKey: "task_timer_seconds")
        }

        // The break's activity, for the same reason: a page opened beside the
        // countdown is what the break *is*. Written before the appearance
        // guard below, so an action that takes the global appearance still
        // keeps its activity.
        parameters = ScheduleActionCard.applyingWebPanel(preferences, to: parameters)

        // Appearance — written only when this action overrides the global
        // settings, and actively cleared when it does not. See
        // `ScheduleActionCard.serializeNotificationPreferences` for why the
        // clearing half matters.
        guard overridesAppearance else {
            parameters = GlobalNotificationSettings.clearingAppearance(parameters)
            return
        }

        // Serialize position and dimensions
        parameters["position"] = preferences.position.rawValue
        if let width = preferences.width {
            parameters["width"] = String(Double(width))
        }
        if let height = preferences.height {
            parameters["height"] = String(Double(height))
        }

        // Serialize behavior settings
        parameters["moveable"] = String(preferences.moveable)
        if let autoDismiss = preferences.autoDismissAfter {
            parameters["auto_dismiss_after"] = String(autoDismiss)
        }
        parameters["screen_blur_enabled"] = String(preferences.screenBlurEnabled)
        parameters["screen_blur_intensity"] = preferences.screenBlurIntensity.rawValue

        logger.debug("🔍 serializeToParameters - END", metadata: [
            "svg_path": "\(parameters["svg_path"] ?? "nil")",
            "svg_width": "\(parameters["svg_width"] ?? "nil")",
            "svg_height": "\(parameters["svg_height"] ?? "nil")",
            "parameterCount": "\(parameters.count)"
        ])
    }

    /// Create ViewModel from Action parameters
    static func fromAction(_ action: Action) -> NotificationActionViewModel {
        let preferences: NotificationPreferences

        // Try to decode preferences from parameters
        if let prefsJSON = action.parameters["preferences"],
           let data = prefsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            preferences = decoded
        } else {
            // Global settings as defaults, per-action keys on top — the same
            // resolution the delivery path performs.
            preferences = GlobalNotificationSettings.current.resolving(
                actionParameters: action.parameters)
        }

        return NotificationActionViewModel(
            preferences: preferences,
            parameters: action.parameters
        )
    }
}
