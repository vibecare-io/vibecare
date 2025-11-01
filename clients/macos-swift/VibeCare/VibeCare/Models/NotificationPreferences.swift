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

// MARK: - Notification Preferences
struct NotificationPreferences: Codable, Equatable, Hashable {
    var svgPath: String?
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

    init(
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
        screenBlurEnabled: Bool = false
    ) {
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
    }

    // MARK: - Default Presets

    static let `default` = NotificationPreferences(
        position: .center,
        width: 450,
        height: 220,
        moveable: true,
        autoDismissAfter: 20.0,
        screenBlurEnabled: false
    )

    static let minimal = NotificationPreferences(
        position: .topRight,
        width: 350,
        height: 150,
        moveable: false,
        autoDismissAfter: 15.0,
        screenBlurEnabled: false
    )

    static let prominent = NotificationPreferences(
        position: .center,
        width: 500,
        height: 300,
        moveable: true,
        autoDismissAfter: 30.0,
        screenBlurEnabled: true
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
}

// MARK: - Preset Management
extension NotificationPreferences {
    static let presets: [String: NotificationPreferences] = [
        "Default": .default,
        "Minimal": .minimal,
        "Prominent": .prominent
    ]

    static var presetNames: [String] {
        return Array(presets.keys).sorted()
    }
}
