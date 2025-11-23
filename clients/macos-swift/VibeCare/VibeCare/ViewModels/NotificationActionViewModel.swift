import Foundation
import SwiftUI
import Logging

/// ViewModel for managing notification action state using Swift's Observation framework
/// This replaces the callback-based pattern with a centralized observable state
@Observable
final class NotificationActionViewModel {
    var preferences: NotificationPreferences
    var parameters: [String: String]

    private let logger = Logger(label: "com.vibecare.notification-action-vm")

    init(preferences: NotificationPreferences, parameters: [String: String]) {
        self.preferences = preferences
        self.parameters = parameters
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

    /// Reset preferences to default
    func resetToDefault() {
        preferences = .default
    }

    /// Apply a preset configuration
    func applyPreset(_ preset: NotificationPreferences) {
        preferences = preset
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
            preferences = .default
        }

        return NotificationActionViewModel(
            preferences: preferences,
            parameters: action.parameters
        )
    }
}
