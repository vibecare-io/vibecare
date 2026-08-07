import Foundation
import SwiftUI

// MARK: - Notification Position
enum NotificationPosition: String, Codable, CaseIterable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var iconName: String {
        switch self {
        case .center: return "circle.grid.cross.fill"
        case .topLeft: return "arrow.up.left.square.fill"
        case .topRight: return "arrow.up.right.square.fill"
        case .bottomLeft: return "arrow.down.left.square.fill"
        case .bottomRight: return "arrow.down.right.square.fill"
        }
    }
}

// MARK: - Blur Intensity
/// Matches VibeNotify 0.0.5 ScreenBlurIntensity enum
enum BlurIntensity: String, Codable, CaseIterable {
    case light   // radius: 10
    case medium  // radius: 25
    case heavy   // radius: 50

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .heavy: return "Heavy"
        }
    }

    var iconName: String {
        switch self {
        case .light: return "circle.dotted"
        case .medium: return "circle.dashed"
        case .heavy: return "circle.fill"
        }
    }
}

// MARK: - Notification Preferences
@Observable
final class NotificationPreferences: Codable, Equatable, Hashable {
    var bundledIconId: String? // ID of bundled SVG icon (e.g., "meditation", "water")
    var svgPath: String? // Custom SVG file path (for user-provided SVGs)
    var svgWidth: CGFloat?
    var svgHeight: CGFloat?
    var title: String?
    var message: String?
    var position: NotificationPosition
    var width: CGFloat?
    var height: CGFloat?
    var moveable: Bool
    var autoDismissAfter: TimeInterval? // Duration in seconds before auto-dismiss
    var screenBlurEnabled: Bool // Enable/disable screen blur background
    var screenBlurIntensity: BlurIntensity // Blur intensity level (VibeNotify 0.0.5+)

    init(
        bundledIconId: String? = nil,
        svgPath: String? = nil,
        svgWidth: CGFloat? = nil,
        svgHeight: CGFloat? = nil,
        title: String? = nil,
        message: String? = nil,
        position: NotificationPosition = .center,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        moveable: Bool = true,
        autoDismissAfter: TimeInterval? = 20.0,
        screenBlurEnabled: Bool = false,
        screenBlurIntensity: BlurIntensity = .medium
    ) {
        self.bundledIconId = bundledIconId
        self.svgPath = svgPath
        self.svgWidth = svgWidth
        self.svgHeight = svgHeight
        self.title = title
        self.message = message
        self.position = position
        self.width = width
        self.height = height
        self.moveable = moveable
        self.autoDismissAfter = autoDismissAfter
        self.screenBlurEnabled = screenBlurEnabled
        self.screenBlurIntensity = screenBlurIntensity
    }

    /// Returns an independent copy of these preferences (a distinct reference,
    /// same field values). Used when seeding per-behavior instances so edits to
    /// one don't mutate the shared singleton or other behaviors.
    func copy() -> NotificationPreferences {
        NotificationPreferences(
            bundledIconId: bundledIconId,
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

    // MARK: - Default Presets

    nonisolated(unsafe) static let `default` = NotificationPreferences(
        position: .center,
        width: 450,
        height: 220,
        moveable: true,
        autoDismissAfter: 20.0,
        screenBlurEnabled: false,
        screenBlurIntensity: .medium
    )

    nonisolated(unsafe) static let minimal = NotificationPreferences(
        position: .topRight,
        width: 350,
        height: 150,
        moveable: false,
        autoDismissAfter: 15.0,
        screenBlurEnabled: false,
        screenBlurIntensity: .light
    )

    nonisolated(unsafe) static let prominent = NotificationPreferences(
        position: .center,
        width: 500,
        height: 300,
        moveable: true,
        autoDismissAfter: 30.0,
        screenBlurEnabled: true,
        screenBlurIntensity: .heavy
    )

    // MARK: - Computed Properties

    var svgSize: CGSize? {
        guard let width = svgWidth, let height = svgHeight else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    var notificationSize: CGSize? {
        guard let width = width, let height = height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Resolves the SVG path/URL
    /// VibeNotify 0.0.4+ supports both file paths and URLs
    /// Since bundled icons are now stored as full URLs, this simply returns svgPath
    var resolvedSVGPath: String? {
        // svgPath now contains full URL for bundled icons (http://localhost:8080/api/icons/id.svg)
        // or file path for custom icons (file:///path/to/icon.svg)
        return svgPath
    }

    /// Returns true if using a bundled icon (URL starts with http), false if custom file or no icon
    var usesBundledIcon: Bool {
        return svgPath?.hasPrefix("http://") == true || svgPath?.hasPrefix("https://") == true
    }

    /// Returns true if an SVG icon is configured
    var hasSVGIcon: Bool {
        return svgPath != nil
    }

    /// Extract icon ID from backend URL for UI purposes
    /// Example: "http://localhost:8080/api/icons/meditation.svg" → "meditation"
    var extractedIconId: String? {
        guard let svgPath = svgPath,
              (svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://")),
              let url = URL(string: svgPath) else {
            return nil
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Message Template Support

    /// Replace template variables in message with actual values
    func formatMessage(
        scheduleName: String,
        routineName: String,
        scheduledTime: Date
    ) -> String {
        guard let template = message else {
            // Default message if none specified
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            timeFormatter.dateStyle = .none
            let timeString = timeFormatter.string(from: scheduledTime)
            return "Routine: \(routineName)\nScheduled: \(timeString)"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        let timeString = timeFormatter.string(from: scheduledTime)

        return template
            .replacingOccurrences(of: "{scheduleName}", with: scheduleName)
            .replacingOccurrences(of: "{routineName}", with: routineName)
            .replacingOccurrences(of: "{time}", with: timeString)
    }

    /// Replace template variables in title with actual values
    func formatTitle(scheduleName: String, routineName: String) -> String {
        guard let template = title else {
            // Default title if none specified
            return "⏰ \(scheduleName)"
        }

        return template
            .replacingOccurrences(of: "{scheduleName}", with: scheduleName)
            .replacingOccurrences(of: "{routineName}", with: routineName)
    }

    // MARK: - Equatable
    static func == (lhs: NotificationPreferences, rhs: NotificationPreferences) -> Bool {
        return lhs.bundledIconId == rhs.bundledIconId &&
            lhs.svgPath == rhs.svgPath &&
            lhs.svgWidth == rhs.svgWidth &&
            lhs.svgHeight == rhs.svgHeight &&
            lhs.title == rhs.title &&
            lhs.message == rhs.message &&
            lhs.position == rhs.position &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.moveable == rhs.moveable &&
            lhs.autoDismissAfter == rhs.autoDismissAfter &&
            lhs.screenBlurEnabled == rhs.screenBlurEnabled &&
            lhs.screenBlurIntensity == rhs.screenBlurIntensity
    }

    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(bundledIconId)
        hasher.combine(svgPath)
        hasher.combine(svgWidth)
        hasher.combine(svgHeight)
        hasher.combine(title)
        hasher.combine(message)
        hasher.combine(position)
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(moveable)
        hasher.combine(autoDismissAfter)
        hasher.combine(screenBlurEnabled)
        hasher.combine(screenBlurIntensity)
    }
}

// MARK: - Preset Management
extension NotificationPreferences {
    nonisolated(unsafe) static let presets: [String: NotificationPreferences] = [
        "Default": .default,
        "Minimal": .minimal,
        "Prominent": .prominent
    ]

    static var presetNames: [String] {
        return Array(presets.keys).sorted()
    }
}
