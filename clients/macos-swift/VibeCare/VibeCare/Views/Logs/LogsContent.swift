import SwiftUI

struct ExecutionLogView: View {
    let searchText: String
    @Binding var selectedId: Int64?

    @State private var hoveredLogId: Int64?
    @State private var sampleLogs: [ExecutionLog] = []

    var filteredLogs: [ExecutionLog] {
        if searchText.isEmpty {
            return sampleLogs
        } else {
            return sampleLogs.filter { log in
                log.routineId.localizedCaseInsensitiveContains(searchText) ||
                (log.notes?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                log.status.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        VStack {
            if filteredLogs.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "No Execution Logs" : "No Matching Logs",
                    subtitle: searchText.isEmpty ? "Logs will appear here when routines are executed" : "No logs match your search",
                    systemImage: "doc.text.circle"
                )
            } else {
                List(filteredLogs, id: \.logId) { log in
                    ExecutionLogRowView(
                        log: log,
                        isSelected: selectedId == log.logId,
                        isHovered: hoveredLogId == log.logId,
                        onSelect: {
                            selectedId = log.logId
                        }
                    )
                    .onHover { isHovered in
                        hoveredLogId = isHovered ? log.logId : nil
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Execution Logs")
        .onAppear {
            loadSampleLogs()
        }
    }

    private func loadSampleLogs() {
        // Create some sample logs for demonstration
        sampleLogs = [
            ExecutionLog(
                logId: 1,
                routineId: "routine-1",
                completed: true,
                notes: "Eye care routine completed successfully",
                actionResults: ["notification": "sent", "sound": "played"]
            ),
            ExecutionLog(
                logId: 2,
                routineId: "routine-2",
                completed: false,
                notes: "Posture reminder failed - sound file not found",
                actionResults: ["notification": "sent", "sound": "error"]
            ),
            ExecutionLog(
                logId: 3,
                routineId: "routine-1",
                completed: true,
                notes: "Hydration reminder completed"
            )
        ]
    }
}

struct ExecutionLogRowView: View {
    let log: ExecutionLog
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Routine: \(log.routineId)")
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: log.statusIcon)
                        .foregroundColor(Color(log.statusColor))
                        .font(.caption)
                }

                if let notes = log.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Text(log.status.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(log.statusColor).opacity(0.1))
                        .foregroundColor(Color(log.statusColor))
                        .clipShape(Capsule())

                    Spacer()

                    Text(log.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.secondary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

#Preview {
    ExecutionLogView(
        searchText: "",
        selectedId: .constant(nil)
    )
}