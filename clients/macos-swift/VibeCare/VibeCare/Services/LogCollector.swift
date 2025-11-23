import Foundation
import Logging

/// Actor-based log collector for storing recent logs in memory
/// Provides thread-safe log collection for future in-app log viewer
actor LogCollector {
    static let shared = LogCollector()

    private var logs: [LogEntry] = []
    private let maxEntries = 1000

    /// Represents a single log entry
    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let label: String
        let message: String
        let metadata: String

        /// Human-readable formatted timestamp
        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
    }

    private init() {}

    /// Append a new log entry
    /// - Parameters:
    ///   - level: Log level (debug, info, warning, error, etc.)
    ///   - label: Logger label (e.g., com.vibecare.notification-action-vm)
    ///   - message: Log message
    ///   - metadata: Additional metadata
    func append(level: String, label: String, message: String, metadata: Logger.Metadata) {
        let entry = LogEntry(
            timestamp: Date(),
            level: level.uppercased(),
            label: label,
            message: message,
            metadata: formatMetadata(metadata)
        )

        logs.append(entry)

        // Keep only recent entries to prevent unbounded memory growth
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }
    }

    /// Get all recent log entries
    /// - Returns: Array of log entries in chronological order
    func getRecentLogs() -> [LogEntry] {
        logs
    }

    /// Get logs filtered by level
    /// - Parameter level: Log level to filter by
    /// - Returns: Filtered log entries
    func getLogsByLevel(_ level: String) -> [LogEntry] {
        logs.filter { $0.level == level.uppercased() }
    }

    /// Get logs filtered by label
    /// - Parameter label: Logger label to filter by
    /// - Returns: Filtered log entries
    func getLogsByLabel(_ label: String) -> [LogEntry] {
        logs.filter { $0.label == label }
    }

    /// Search logs by message content
    /// - Parameter query: Search query
    /// - Returns: Matching log entries
    func searchLogs(_ query: String) -> [LogEntry] {
        let lowercaseQuery = query.lowercased()
        return logs.filter {
            $0.message.lowercased().contains(lowercaseQuery) ||
            $0.metadata.lowercased().contains(lowercaseQuery)
        }
    }

    /// Clear all collected logs
    func clear() {
        logs.removeAll()
    }

    /// Get statistics about collected logs
    /// - Returns: Dictionary with log counts by level
    func getStatistics() -> [String: Int] {
        var stats: [String: Int] = [:]
        for entry in logs {
            stats[entry.level, default: 0] += 1
        }
        return stats
    }

    // MARK: - Private Helpers

    private func formatMetadata(_ metadata: Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return "" }

        return metadata.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: ", ")
    }
}
