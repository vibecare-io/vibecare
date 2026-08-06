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

/// Immediate screen lock. A seam so the handler can be unit-tested without
/// actually locking the machine (the real locker locks the session for real).
protocol ScreenLocker {
    func lock() throws
}

/// Real locker: calls the private `SACLockScreenImmediate()` in login.framework.
///
/// Chosen over the old `CGSession -suspend` (removed by Apple; gone in macOS 26)
/// and over `pmset displaysleepnow` because it locks the session *immediately and
/// unconditionally* — it does not depend on the user's "require password after
/// sleep" setting — with no subprocess and no Accessibility/TCC prompt. The app is
/// unsandboxed and ships outside the App Store, so the private symbol is acceptable.
struct LoginFrameworkLocker: ScreenLocker {
    enum LockError: Error, Equatable {
        case frameworkUnavailable(String)
        case symbolUnavailable
    }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/login"

    func lock() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            throw LockError.frameworkUnavailable(String(cString: dlerror()))
        }
        // Intentionally not dlclose'd: the symbol lives in the dyld shared cache,
        // and keeping the handle open avoids any teardown race on repeat locks.
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            throw LockError.symbolUnavailable
        }
        typealias LockFn = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFn.self)()
        // The return value's semantics are undocumented, so resolving and calling
        // the symbol is our success signal; a silent no-op can't be detected here.
    }
}

@MainActor
final class SystemCommandHandler {
    static let shared = SystemCommandHandler()

    private static let pmset = "/usr/bin/pmset"

    typealias CountdownPresenter =
        @MainActor (_ seconds: Int, _ cancelable: Bool, _ message: String?, _ onComplete: @escaping () -> Void) -> Void

    private let runner: CommandRunner
    private let screenLocker: ScreenLocker
    private let presentCountdown: CountdownPresenter
    private let logger = Logger(label: "com.vibecare.system-command")

    init(runner: CommandRunner = ProcessCommandRunner(),
         screenLocker: ScreenLocker = LoginFrameworkLocker(),
         presentCountdown: @escaping CountdownPresenter = { s, c, m, done in
             SleepCountdownOverlay.shared.present(seconds: s, cancelable: c, message: m, onComplete: done)
         }) {
        self.runner = runner
        self.screenLocker = screenLocker
        self.presentCountdown = presentCountdown
    }

    /// Entry point called by EventService for `.systemCommand` actions.
    /// When `countdownSeconds > 0`, presents the cancelable overlay and defers
    /// execution until it completes; `0` runs immediately (no overlay).
    func executeAction(_ action: Action) {
        guard action.type == .systemCommand else {
            logger.error("Invalid action type for SystemCommandHandler: \(action.type)")
            return
        }
        guard let request = SystemCommandRequest.parse(from: action.parameters) else {
            logger.error("Unrecognized system command in action \(action.id): \(action.parameters)")
            return
        }
        if request.countdownSeconds > 0 {
            presentCountdown(request.countdownSeconds, request.cancelable, request.message) {
                [weak self] in self?.perform(request.type)
            }
        } else {
            perform(request.type)
        }
    }

    /// Execute a command. `lock` surfaces failure via the log; `sleep` treats the
    /// lock as best-effort and always attempts to sleep, so a lock-mechanism
    /// failure can never again silently prevent the machine from sleeping.
    func perform(_ type: SystemCommandType) {
        switch type {
        case .lock:
            do {
                try lockScreen()
            } catch {
                logger.error("Lock failed: \(error)")
            }
        case .sleep:
            do {
                try lockScreen()
            } catch {
                logger.error("Lock before sleep failed; sleeping anyway: \(error)")
            }
            do {
                try runner.run(executable: Self.pmset, arguments: ["sleepnow"])
                logger.info("Slept via pmset sleepnow")
            } catch {
                logger.error("Sleep failed: \(error)")
            }
        case .displaySleep, .logout, .shutdown, .restart:
            logger.warning("System command '\(type.rawValue)' not implemented on macOS yet")
        }
    }

    /// Lock via login.framework; if that mechanism is unavailable (e.g. a future
    /// macOS removes the symbol), fall back to `pmset displaysleepnow`, which
    /// locks on wake when the user requires a password.
    private func lockScreen() throws {
        do {
            try screenLocker.lock()
            logger.info("Locked screen via login.framework")
        } catch {
            logger.warning("Primary lock unavailable (\(error)); falling back to pmset displaysleepnow")
            try runner.run(executable: Self.pmset, arguments: ["displaysleepnow"])
        }
    }
}
