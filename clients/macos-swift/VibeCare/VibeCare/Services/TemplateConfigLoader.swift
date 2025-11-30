import Foundation
import Logging

/// Loads routine schedule templates from external JSON configuration
class TemplateConfigLoader {
    nonisolated(unsafe) static let shared = TemplateConfigLoader()

    private let logger = Logger(label: "com.vibecare.template-loader")
    private var cachedTemplates: [RoutineScheduleTemplate]?

    private init() {}

    /// Load all templates from TemplateConfigs.json
    func loadTemplates() -> [RoutineScheduleTemplate] {
        // Return cached if available
        if let cached = cachedTemplates {
            return cached
        }

        guard let url = Bundle.main.url(forResource: "TemplateConfigs", withExtension: "json") else {
            logger.error("TemplateConfigs.json not found in bundle")
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(TemplateConfig.self, from: data)

            let templates = config.templates.map { convertToTemplate($0) }
            cachedTemplates = templates

            logger.info("Loaded \(templates.count) templates from config (version: \(config.version))")
            return templates

        } catch {
            logger.error("Failed to load templates: \(error)")
            return []
        }
    }

    /// Clear cache (useful for hot-reload in development)
    func clearCache() {
        cachedTemplates = nil
    }

    // MARK: - Private Conversion

    private func convertToTemplate(_ config: TemplateConfigItem) -> RoutineScheduleTemplate {
        // Parse category
        let category: TemplateCategory
        switch config.category {
        case "daily":
            category = .daily
        case "weekly":
            category = .weekly
        case "monthly_yearly":
            category = .monthlyYearly
        default:
            category = .daily
        }

        // Parse times
        let defaultTimes = config.default_times.compactMap { timeString -> TimeComponents? in
            let parts = timeString.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else {
                return nil
            }
            return TimeComponents(hour: hour, minute: minute)
        }

        // Create suggested action from notification config
        var suggestedActions: [ActionTemplate] = []
        if let notif = config.notification {
            // Build icon URL if icon_id is provided
            var parameters: [String: String] = [
                "title": notif.title,
                "body": notif.body,
                "position": notif.position ?? "center",
                "auto_dismiss_after": String(notif.auto_dismiss ?? 20),
                "width": String(notif.width ?? 450),
                "height": String(notif.height ?? 220)
            ]

            if let iconId = notif.icon_id, !iconId.isEmpty {
                parameters["svg_path"] = NetworkConfiguration.buildIconURL(iconId: iconId)
                parameters["svg_width"] = "350"
                parameters["svg_height"] = "320"
            }

            let actionTemplate = ActionTemplate(
                type: .notification,
                name: notif.title,
                parameters: parameters
            )
            suggestedActions.append(actionTemplate)
        }

        return RoutineScheduleTemplate(
            id: config.id,
            category: category,
            routineName: config.routine_name,
            routineDescription: config.routine_description ?? "",
            routineIcon: config.routine_icon,
            routineColor: config.routine_color,
            scheduleName: config.schedule_name,
            scheduleDescription: config.schedule_description ?? "",
            rruleString: config.rrule,
            defaultTimes: defaultTimes,
            suggestedActions: suggestedActions
        )
    }
}

// MARK: - JSON Codable Structures

private struct TemplateConfig: Codable {
    let version: String
    let templates: [TemplateConfigItem]
}

private struct TemplateConfigItem: Codable {
    let id: String
    let category: String
    let routine_name: String
    let routine_description: String?
    let routine_icon: String
    let routine_color: String
    let schedule_name: String
    let schedule_description: String?
    let rrule: String
    let default_times: [String]
    let notification: NotificationConfigItem?
}

private struct NotificationConfigItem: Codable {
    let title: String
    let body: String
    let icon_id: String?
    let position: String?
    let auto_dismiss: Int?
    let width: Int?
    let height: Int?
}
