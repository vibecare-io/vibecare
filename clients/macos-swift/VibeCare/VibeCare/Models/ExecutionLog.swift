import Foundation

struct ExecutionLog: Identifiable, Codable, Equatable, Hashable {
    let logId: Int64
    let routineId: String
    let timestamp: Date
    let completed: Bool
    let notes: String?
    let actionResults: [String: String]?

    init(
        logId: Int64 = 0,
        routineId: String,
        timestamp: Date = Date(),
        completed: Bool,
        notes: String? = nil,
        actionResults: [String: String]? = nil
    ) {
        self.logId = logId
        self.routineId = routineId
        self.timestamp = timestamp
        self.completed = completed
        self.notes = notes
        self.actionResults = actionResults
    }

    var id: Int64 { logId }
}

// MARK: - ExecutionLog Extensions
extension ExecutionLog {
    var status: ExecutionStatus {
        if completed {
            return .success
        } else if let results = actionResults {
            return results.values.contains { $0.contains("error") } ? .failed : .partial
        } else {
            return .failed
        }
    }

    var statusColor: String {
        switch status {
        case .success: return "green"
        case .partial: return "orange"
        case .failed: return "red"
        case .skipped: return "gray"
        }
    }

    var statusIcon: String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    var displayNotes: String {
        notes ?? (completed ? "Completed successfully" : "Execution failed")
    }
}

enum ExecutionStatus {
    case success
    case partial
    case failed
    case skipped

    var displayName: String {
        switch self {
        case .success: return "Success"
        case .partial: return "Partial"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

