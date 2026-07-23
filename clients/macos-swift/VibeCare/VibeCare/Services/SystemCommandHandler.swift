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

@MainActor
final class SystemCommandHandler {
    static let shared = SystemCommandHandler()

    private static let cgSession =
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    private static let pmset = "/usr/bin/pmset"

    private let runner: CommandRunner
    private let logger = Logger(label: "com.vibecare.system-command")

    init(runner: CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// The ordered native invocations for a command type on macOS.
    /// Unimplemented commands return [] (logged + no-op by the caller).
    static func invocations(
        for type: SystemCommandType
    ) -> [(executable: String, arguments: [String])] {
        let lock = (executable: cgSession, arguments: ["-suspend"])
        switch type {
        case .lock:
            return [lock]
        case .sleep:
            return [lock, (executable: pmset, arguments: ["sleepnow"])]
        case .displaySleep, .logout, .shutdown, .restart:
            return []   // not implemented in this milestone
        }
    }

    /// Entry point called by EventService for `.systemCommand` actions.
    /// M0: only immediate (countdown == 0) execution. Countdown handling is
    /// wired in M1.
    func executeAction(_ action: Action) {
        guard action.type == .systemCommand else {
            logger.error("Invalid action type for SystemCommandHandler: \(action.type)")
            return
        }
        guard let request = SystemCommandRequest.parse(from: action.parameters) else {
            logger.error("Unrecognized system command in action \(action.id): \(action.parameters)")
            return
        }
        // M1 replaces this branch with the countdown overlay when > 0.
        runInvocations(for: request.type)
    }

    /// Run the ordered invocations for a command type, stopping on the first error.
    func runInvocations(for type: SystemCommandType) {
        let invocations = Self.invocations(for: type)
        if invocations.isEmpty {
            logger.warning("System command '\(type.rawValue)' not implemented on macOS yet")
            return
        }
        for inv in invocations {
            do {
                try runner.run(executable: inv.executable, arguments: inv.arguments)
                logger.info("Ran system command: \(inv.executable) \(inv.arguments.joined(separator: " "))")
            } catch {
                logger.error("System command failed: \(inv.executable) — \(error)")
                return   // stop the sequence; surfaced to the user in M0.5/M1
            }
        }
    }
}
