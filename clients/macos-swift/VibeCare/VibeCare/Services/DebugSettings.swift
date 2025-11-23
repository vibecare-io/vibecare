import Foundation
import SwiftUI
import Logging

/// Singleton for managing debug-related settings
/// Controls log levels and log collection for the entire app
final class DebugSettings: ObservableObject {
    nonisolated(unsafe) static let shared = DebugSettings()

    /// Current log level - controls which messages are shown
    /// Thread-safe access via nonisolated getter
    /// - .trace: Most verbose (all messages)
    /// - .debug: Debug information (includes 🔍 icon logs)
    /// - .info: General information (default for development)
    /// - .notice: Important information (default for production)
    /// - .warning: Warning messages
    /// - .error: Error messages only
    /// - .critical: Critical errors only
    @Published var currentLogLevel: Logger.Level {
        didSet {
            _currentLogLevelAtomic.store(currentLogLevel)
            UserDefaults.standard.set(currentLogLevel.rawValue, forKey: "debug_log_level")
        }
    }

    /// Enable collection of logs in memory for in-app viewing
    /// When enabled, logs are stored in LogCollector for future in-app viewer
    @Published var collectLogsEnabled: Bool {
        didSet {
            _collectLogsEnabledAtomic.store(collectLogsEnabled)
            UserDefaults.standard.set(collectLogsEnabled, forKey: "debug_collect_logs_enabled")
        }
    }

    // Thread-safe atomic storage for nonisolated access
    private let _currentLogLevelAtomic: AtomicLogLevel
    private let _collectLogsEnabledAtomic: AtomicBool

    private init() {
        // Load saved log level, default to .info (hides debug and trace)
        let savedLevel = UserDefaults.standard.string(forKey: "debug_log_level") ?? "info"
        let initialLevel = Logger.Level(rawValue: savedLevel) ?? .info
        self.currentLogLevel = initialLevel
        self._currentLogLevelAtomic = AtomicLogLevel(initialLevel)

        // Load saved log collection preference, default to false
        let initialCollect = UserDefaults.standard.bool(forKey: "debug_collect_logs_enabled")
        self.collectLogsEnabled = initialCollect
        self._collectLogsEnabledAtomic = AtomicBool(initialCollect)
    }

    /// Thread-safe getter for log level (callable from any thread)
    nonisolated func getLogLevel() -> Logger.Level {
        _currentLogLevelAtomic.load()
    }

    /// Thread-safe getter for collect logs enabled (callable from any thread)
    nonisolated func getCollectLogsEnabled() -> Bool {
        _collectLogsEnabledAtomic.load()
    }

    /// Reset to default settings
    @MainActor
    func resetToDefaults() {
        currentLogLevel = .info
        collectLogsEnabled = false
    }
}

// MARK: - Atomic Wrappers

/// Thread-safe atomic storage for Logger.Level
private final class AtomicLogLevel {
    private let lock = NSLock()
    private var value: Logger.Level

    init(_ initialValue: Logger.Level) {
        self.value = initialValue
    }

    func load() -> Logger.Level {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ newValue: Logger.Level) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Thread-safe atomic storage for Bool
private final class AtomicBool {
    private let lock = NSLock()
    private var value: Bool

    init(_ initialValue: Bool) {
        self.value = initialValue
    }

    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Extension to make Logger.Level conform to Identifiable for Picker
extension Logger.Level: @retroactive Identifiable {
    public var id: String { rawValue }
}
