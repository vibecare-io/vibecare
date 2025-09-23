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

// MARK: - Sample Data
extension ExecutionLog {
    static func samples(for routines: [Routine]) -> [ExecutionLog] {
        guard !routines.isEmpty else { return [] }

        let now = Date()
        let calendar = Calendar.current

        return [
            // Recent successful execution
            ExecutionLog(
                logId: 1,
                routineId: routines[0].id,
                timestamp: calendar.date(byAdding: .minute, value: -5, to: now) ?? now,
                completed: true,
                notes: "Eye care reminder completed",
                actionResults: [
                    "action_1": "notification_sent",
                    "action_2": "sound_played"
                ]
            ),

            // Partial execution from an hour ago
            ExecutionLog(
                logId: 2,
                routineId: routines[0].id,
                timestamp: calendar.date(byAdding: .hour, value: -1, to: now) ?? now,
                completed: false,
                notes: "Notification sent but sound failed",
                actionResults: [
                    "action_1": "notification_sent",
                    "action_2": "error: sound file not found"
                ]
            ),

            // Successful execution from 2 hours ago
            ExecutionLog(
                logId: 3,
                routineId: routines.count > 1 ? routines[1].id : routines[0].id,
                timestamp: calendar.date(byAdding: .hour, value: -2, to: now) ?? now,
                completed: true,
                notes: "Posture reminder completed",
                actionResults: [
                    "action_1": "notification_sent"
                ]
            ),

            // Failed execution from yesterday
            ExecutionLog(
                logId: 4,
                routineId: routines.count > 2 ? routines[2].id : routines[0].id,
                timestamp: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
                completed: false,
                notes: "Network error - could not send notification",
                actionResults: [
                    "action_1": "error: network timeout"
                ]
            ),

            // Successful execution from 2 days ago
            ExecutionLog(
                logId: 5,
                routineId: routines[0].id,
                timestamp: calendar.date(byAdding: .day, value: -2, to: now) ?? now,
                completed: true,
                notes: "Eye care routine completed successfully"
            )
        ]
    }
}