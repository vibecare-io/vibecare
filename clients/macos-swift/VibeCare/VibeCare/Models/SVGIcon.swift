//
//  SVGIcon.swift
//  vibecare
//
//  Created by Claude Code on 2025-11-06.
//

import Foundation
import VCStubs

/// Represents an SVG icon with metadata (can be from backend or local bundle)
struct SVGIcon: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: IconCategory
    let filename: String
    let keywords: [String]

    /// Whether this icon is from backend (true) or local bundle (false)
    let isBackendIcon: Bool

    /// Returns the full file path to this icon in the app bundle (fallback for local icons)
    var bundlePath: String? {
        // Try multiple strategies to find the SVG file

        // Strategy 1: Try with subdirectory
        if let path = Bundle.main.path(forResource: id, ofType: "svg", inDirectory: "Resources/SVGIcons") {
            return path
        }

        // Strategy 2: Try without subdirectory
        if let path = Bundle.main.path(forResource: id, ofType: "svg") {
            return path
        }

        // Strategy 3: Try with filename directly
        if let path = Bundle.main.path(forResource: filename, ofType: nil) {
            return path
        }

        // Strategy 4: Search in all bundle resources
        if let url = Bundle.main.urls(forResourcesWithExtension: "svg", subdirectory: nil)?
            .first(where: { $0.lastPathComponent == filename || $0.deletingPathExtension().lastPathComponent == id }) {
            return url.path
        }

        return nil
    }

    /// Returns the URL for this icon - computed dynamically from UserDefaults
    var iconURL: URL? {
        if isBackendIcon {
            // Read backend URL from UserDefaults every time (always fresh)
            let backendURLString = UserDefaults.standard.string(forKey: "backend_url") ?? "http://localhost:8080"
            guard let baseURL = URL(string: backendURLString) else {
                return nil
            }

            // Build icon URL: {backend_url}/api/icons/{id}.svg
            return baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("icons")
                .appendingPathComponent("\(id).svg")
        } else {
            // Local bundle icon
            if let bundlePath = bundlePath {
                return URL(fileURLWithPath: bundlePath)
            }
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, filename, keywords, isBackendIcon
    }

    // MARK: - Protobuf Conversion

    /// Initialize from protobuf message (backend icon)
    init(from proto: VCSVGIcon) {
        self.id = proto.id
        self.name = proto.name
        self.category = IconCategory(rawValue: proto.category) ?? .health
        self.filename = proto.filename
        self.keywords = proto.keywords
        self.isBackendIcon = true  // Icon from backend
    }

    /// Legacy initializer for local bundle icons (used by previews and fallbacks)
    init(id: String, name: String, category: IconCategory, filename: String, keywords: [String]) {
        self.id = id
        self.name = name
        self.category = category
        self.filename = filename
        self.keywords = keywords
        self.isBackendIcon = false  // Icon from local bundle
    }
}

/// Icon categories for organizing the icon picker
enum IconCategory: String, Codable, CaseIterable, Identifiable {
    case health
    case productivity
    case communication
    case lifestyle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .health:
            return "Health & Wellness"
        case .productivity:
            return "Productivity"
        case .communication:
            return "Communication"
        case .lifestyle:
            return "Lifestyle"
        }
    }

    var description: String {
        switch self {
        case .health:
            return "Icons for health, wellness, and self-care routines"
        case .productivity:
            return "Icons for work, focus, and time management"
        case .communication:
            return "Icons for meetings, messages, and notifications"
        case .lifestyle:
            return "Icons for daily activities and hobbies"
        }
    }

    var order: Int {
        switch self {
        case .health: return 1
        case .productivity: return 2
        case .communication: return 3
        case .lifestyle: return 4
        }
    }

    /// System icon for the category tab
    var symbolName: String {
        switch self {
        case .health:
            return "heart.fill"
        case .productivity:
            return "checkmark.circle.fill"
        case .communication:
            return "bubble.left.fill"
        case .lifestyle:
            return "figure.walk"
        }
    }
}

/// Container for the icon catalog JSON structure
struct SVGIconCatalog: Codable {
    let version: String
    let icons: [SVGIcon]
    let categories: [String: CategoryMetadata]

    struct CategoryMetadata: Codable {
        let id: String
        let name: String
        let description: String
        let order: Int
    }
}

// MARK: - Convenience Extensions

extension SVGIcon {
    /// Check if this icon matches a search query
    func matches(searchQuery: String) -> Bool {
        guard !searchQuery.isEmpty else { return true }

        let query = searchQuery.lowercased()

        // Search in name
        if name.lowercased().contains(query) {
            return true
        }

        // Search in keywords
        if keywords.contains(where: { $0.lowercased().contains(query) }) {
            return true
        }

        return false
    }
}

extension Collection where Element == SVGIcon {
    /// Filter icons by category
    func filtered(by category: IconCategory) -> [SVGIcon] {
        return self.filter { $0.category == category }
    }

    /// Filter icons by search query
    func filtered(by searchQuery: String) -> [SVGIcon] {
        guard !searchQuery.isEmpty else { return Array(self) }
        return self.filter { $0.matches(searchQuery: searchQuery) }
    }

    /// Group icons by category
    func groupedByCategory() -> [IconCategory: [SVGIcon]] {
        return Dictionary(grouping: self) { $0.category }
    }
}
