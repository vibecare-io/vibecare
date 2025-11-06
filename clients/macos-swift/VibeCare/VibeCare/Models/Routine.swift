import Foundation

struct Routine: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let profileId: String
    var name: String
    var description: String
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

