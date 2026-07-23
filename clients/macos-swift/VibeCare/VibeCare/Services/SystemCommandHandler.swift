import Foundation
import Logging

/// Platform-neutral system command vocabulary. Each platform client maps the
/// same case to its own native invocation (see docs/cross-platform-system-commands.md).
enum SystemCommandType: String {
    case lock
    case sleep
    case displaySleep = "display_sleep"
    case logout
    case shutdown
    case restart
}

struct SystemCommandRequest: Equatable {
    let type: SystemCommandType
    let countdownSeconds: Int
    let cancelable: Bool
    let message: String?

    /// Parse from an Action's parameters map. Returns nil if `command` is
    /// missing or not a known vocabulary term.
    static func parse(from parameters: [String: String]) -> SystemCommandRequest? {
        guard let raw = parameters["command"],
              let type = SystemCommandType(rawValue: raw) else {
            return nil
        }
        let countdown = parameters["countdown_seconds"].flatMap { Int($0) } ?? 0
        let cancelable = (parameters["cancelable"] ?? "true").lowercased() != "false"
        let message = parameters["message"]?.isEmpty == false ? parameters["message"] : nil
        return SystemCommandRequest(type: type,
                                    countdownSeconds: max(0, countdown),
                                    cancelable: cancelable,
                                    message: message)
    }
}
