import Foundation

struct Routine: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let profileId: String
    var name: String
    var description: String
    var actionIds: [String]
    var enabled: Bool
    var metadata: [String: String]
    let createdAt: Date
    var updatedAt: Date
    var lastExecutedAt: Date?

    init(
        id: String = UUID().uuidString,
        profileId: String,
        name: String,
        description: String = "",
        actionIds: [String] = [],
        enabled: Bool = true,
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastExecutedAt: Date? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.name = name
        self.description = description
        self.actionIds = actionIds
        self.enabled = enabled
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastExecutedAt = lastExecutedAt
    }
}

// MARK: - Routine Extensions
extension Routine {
    var category: String {
        metadata["category"] ?? "General"
    }

    var color: String {
        metadata["color"] ?? "blue"
    }

    var iconName: String {
        metadata["icon"] ?? "list.bullet"
    }

    var tags: [String] {
        metadata["tags"]?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    mutating func updateMetadata(category: String? = nil, color: String? = nil, icon: String? = nil, tags: [String]? = nil) {
        if let category = category {
            metadata["category"] = category
        }
        if let color = color {
            metadata["color"] = color
        }
        if let icon = icon {
            metadata["icon"] = icon
        }
        if let tags = tags {
            metadata["tags"] = tags.joined(separator: ", ")
        }
        updatedAt = Date()
    }
}

// MARK: - Sample Data
extension Routine {
    static func samples(for profileId: String, with actions: [Action]) -> [Routine] {
        let eyeCareActions = actions.filter { $0.name.contains("Eye") || $0.name.contains("20-20-20") }
        let postureActions = actions.filter { $0.name.contains("Posture") || $0.name.contains("back") }
        let soundActions = actions.filter { $0.type == .playSound }
        let notificationActions = actions.filter { $0.type == .notification }

        return [
            Routine(
                profileId: profileId,
                name: "20-20-20 Eye Care Rule",
                description: "Save your eyes with the 20-20-20 rule - every 20 minutes, look at something 20 feet away for 20 seconds",
                actionIds: eyeCareActions.map(\.id),
                metadata: [
                    "category": "Health",
                    "color": "green",
                    "icon": "eye",
                    "tags": "eye care, health, break"
                ]
            ),
            Routine(
                profileId: profileId,
                name: "Posture Check Reminder",
                description: "Regular reminders to maintain good posture while working",
                actionIds: postureActions.map(\.id),
                metadata: [
                    "category": "Health",
                    "color": "orange",
                    "icon": "figure.seated.side",
                    "tags": "posture, health, ergonomics"
                ]
            ),
            Routine(
                profileId: profileId,
                name: "Hydration Reminder",
                description: "Stay hydrated throughout the day",
                actionIds: notificationActions.prefix(1).map(\.id),
                metadata: [
                    "category": "Health",
                    "color": "blue",
                    "icon": "drop",
                    "tags": "hydration, health, water"
                ]
            ),
            Routine(
                profileId: profileId,
                name: "Focus Break",
                description: "Take a short break to refresh your mind",
                actionIds: (soundActions + notificationActions.prefix(1)).map(\.id),
                metadata: [
                    "category": "Productivity",
                    "color": "purple",
                    "icon": "brain.head.profile",
                    "tags": "focus, break, productivity"
                ]
            ),
            Routine(
                profileId: profileId,
                name: "Evening Wind Down",
                description: "Prepare for a restful night's sleep",
                actionIds: soundActions.map(\.id),
                enabled: false,
                metadata: [
                    "category": "Sleep",
                    "color": "indigo",
                    "icon": "moon.stars",
                    "tags": "sleep, evening, relaxation"
                ]
            )
        ]
    }
}