import Foundation

struct Action: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let profileId: String
    var type: ActionType
    var name: String
    var description: String
    var parameters: [String: String]
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        profileId: String,
        type: ActionType,
        name: String,
        description: String = "",
        parameters: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.type = type
        self.name = name
        self.description = description
        self.parameters = parameters
        self.createdAt = createdAt
    }
}

enum ActionType: String, Codable, CaseIterable {
    case notification = "notification"
    case openLink = "open_link"
    case sendEmail = "send_email"
    case runScript = "run_script"
    case playSound = "play_sound"
    case systemCommand = "system_command"
    case apiCall = "api_call"
    case logEntry = "log_entry"

    var displayName: String {
        switch self {
        case .notification: return "Send Notification"
        case .openLink: return "Open Link"
        case .sendEmail: return "Send Email"
        case .runScript: return "Run Script"
        case .playSound: return "Play Sound"
        case .systemCommand: return "System Command"
        case .apiCall: return "API Call"
        case .logEntry: return "Log Entry"
        }
    }

    var iconName: String {
        switch self {
        case .notification: return "bell"
        case .openLink: return "link"
        case .sendEmail: return "envelope"
        case .runScript: return "terminal"
        case .playSound: return "speaker.wave.2"
        case .systemCommand: return "gearshape"
        case .apiCall: return "network"
        case .logEntry: return "doc.text"
        }
    }

    var color: String {
        switch self {
        case .notification: return "blue"
        case .openLink: return "purple"
        case .sendEmail: return "green"
        case .runScript: return "orange"
        case .playSound: return "yellow"
        case .systemCommand: return "red"
        case .apiCall: return "indigo"
        case .logEntry: return "gray"
        }
    }

    var requiredParameters: [ActionParameter] {
        switch self {
        case .notification:
            return [
                ActionParameter(name: "title", type: .string, required: true, description: "Notification title"),
                ActionParameter(name: "body", type: .string, required: true, description: "Notification body"),
                ActionParameter(name: "sound", type: .string, required: false, description: "Sound name")
            ]
        case .openLink:
            return [
                ActionParameter(name: "url", type: .string, required: true, description: "URL to open")
            ]
        case .sendEmail:
            return [
                ActionParameter(name: "to", type: .string, required: true, description: "Recipient email"),
                ActionParameter(name: "subject", type: .string, required: true, description: "Email subject"),
                ActionParameter(name: "body", type: .string, required: true, description: "Email body")
            ]
        case .runScript:
            return [
                ActionParameter(name: "script", type: .string, required: true, description: "Script to execute"),
                ActionParameter(name: "interpreter", type: .string, required: false, description: "Script interpreter")
            ]
        case .playSound:
            return [
                ActionParameter(name: "sound_file", type: .string, required: true, description: "Sound file path"),
                ActionParameter(name: "volume", type: .number, required: false, description: "Volume (0-100)")
            ]
        case .systemCommand:
            return [
                ActionParameter(name: "command", type: .string, required: true, description: "System command to execute")
            ]
        case .apiCall:
            return [
                ActionParameter(name: "url", type: .string, required: true, description: "API endpoint URL"),
                ActionParameter(name: "method", type: .string, required: true, description: "HTTP method"),
                ActionParameter(name: "headers", type: .object, required: false, description: "HTTP headers"),
                ActionParameter(name: "body", type: .object, required: false, description: "Request body")
            ]
        case .logEntry:
            return [
                ActionParameter(name: "message", type: .string, required: true, description: "Log message"),
                ActionParameter(name: "level", type: .string, required: false, description: "Log level")
            ]
        }
    }
}

struct ActionParameter {
    let name: String
    let type: ParameterType
    let required: Bool
    let description: String
    let defaultValue: String?
    let allowedValues: [String]?

    init(
        name: String,
        type: ParameterType,
        required: Bool,
        description: String,
        defaultValue: String? = nil,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.defaultValue = defaultValue
        self.allowedValues = allowedValues
    }
}

enum ParameterType: String, Codable {
    case string
    case number
    case boolean
    case array
    case object

    var displayName: String {
        switch self {
        case .string: return "Text"
        case .number: return "Number"
        case .boolean: return "Yes/No"
        case .array: return "List"
        case .object: return "Object"
        }
    }
}

// MARK: - Sample Data
extension Action {
    static func samples(for profileId: String) -> [Action] {
        [
            Action(
                profileId: profileId,
                type: .notification,
                name: "20-20-20 Eye Care Reminder",
                description: "Reminds to look at something 20 feet away for 20 seconds",
                parameters: [
                    "title": "Eye Care Reminder",
                    "body": "Look at something 20 feet away for 20 seconds",
                    "sound": "default"
                ]
            ),
            Action(
                profileId: profileId,
                type: .openLink,
                name: "Open Health Dashboard",
                description: "Opens the health dashboard in browser",
                parameters: [
                    "url": "https://health.example.com/dashboard"
                ]
            ),
            Action(
                profileId: profileId,
                type: .runScript,
                name: "Posture Check",
                description: "Runs posture check script",
                parameters: [
                    "script": "osascript -e 'display notification \"Straighten your back!\" with title \"Posture Check\"'",
                    "interpreter": "sh"
                ]
            ),
            Action(
                profileId: profileId,
                type: .playSound,
                name: "Gentle Bell",
                description: "Plays a gentle bell sound",
                parameters: [
                    "sound_file": "/System/Library/Sounds/Bell.aiff",
                    "volume": "50"
                ]
            )
        ]
    }
}