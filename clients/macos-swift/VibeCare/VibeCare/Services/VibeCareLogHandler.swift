import Logging
import Foundation

/// Custom log handler that respects user-configurable log levels
/// Integrates with DebugSettings to allow runtime log level changes
struct VibeCareLogHandler: LogHandler {
    private let label: String
    private var streamHandler: StreamLogHandler

    // Log level controlled by DebugSettings
    var logLevel: Logger.Level {
        get {
            // Use nonisolated thread-safe getter
            DebugSettings.shared.getLogLevel()
        }
        set {
            // Ignore setter - log level controlled by DebugSettings
            // This satisfies LogHandler protocol requirement
        }
    }

    var metadata: Logger.Metadata = [:]

    init(label: String) {
        self.label = label
        self.streamHandler = StreamLogHandler.standardOutput(label: label)
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Check if this log level should be output based on settings
        guard level >= logLevel else { return }

        // Optionally collect logs for in-app viewer (thread-safe access)
        if DebugSettings.shared.getCollectLogsEnabled() {
            Task {
                await LogCollector.shared.append(
                    level: level.rawValue,
                    label: label,
                    message: message.description,
                    metadata: (metadata ?? [:]).merging(self.metadata) { $1 }
                )
            }
        }

        // Delegate actual logging to standard output handler
        streamHandler.log(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }
}
