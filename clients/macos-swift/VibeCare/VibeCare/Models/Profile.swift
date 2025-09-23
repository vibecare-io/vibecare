import Foundation

struct Profile: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var email: String
    var preferences: [String: String]
    var devices: [Device]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        email: String,
        preferences: [String: String] = [:],
        devices: [Device] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.preferences = preferences
        self.devices = devices
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Device: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var type: DeviceType
    var pushToken: String?
    var lastSeen: Date
    var active: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        type: DeviceType,
        pushToken: String? = nil,
        lastSeen: Date = Date(),
        active: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.pushToken = pushToken
        self.lastSeen = lastSeen
        self.active = active
    }
}

enum DeviceType: String, Codable, CaseIterable {
    case macOS = "macos"
    case iOS = "ios"
    case linux = "linux"
    case android = "android"
    case windows = "windows"

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .linux: return "Linux"
        case .android: return "Android"
        case .windows: return "Windows"
        }
    }

    var iconName: String {
        switch self {
        case .macOS: return "laptopcomputer"
        case .iOS: return "iphone"
        case .linux: return "desktopcomputer"
        case .android: return "smartphone"
        case .windows: return "pc"
        }
    }
}

// MARK: - Sample Data
extension Profile {
    static let sample = Profile(
        name: "John Doe",
        email: "john@example.com",
        preferences: [
            "theme": "dark",
            "notifications": "enabled",
            "autoStart": "true"
        ],
        devices: [
            Device(
                name: "MacBook Pro",
                type: .macOS,
                lastSeen: Date()
            ),
            Device(
                name: "iPhone 15",
                type: .iOS,
                lastSeen: Date().addingTimeInterval(-3600)
            )
        ]
    )
}