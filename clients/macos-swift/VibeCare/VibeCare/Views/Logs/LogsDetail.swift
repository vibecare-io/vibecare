import SwiftUI

struct ExecutionLogDetailView: View {
    let log: ExecutionLog?

    var body: some View {
        Group {
            if let log = log {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Log Header
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: log.status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(log.status == .success ? .green : .red)

                                VStack(alignment: .leading) {
                                    Text("Execution Log")
                                        .font(.largeTitle)
                                        .fontWeight(.bold)

                                    Text(log.status.displayName)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(log.status == .success ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                        .clipShape(Capsule())
                                }

                                Spacer()
                            }
                        }

                        Divider()

                        // Log Details
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(title: "Routine ID", value: log.routineId)
                            DetailRow(title: "Status", value: log.status.displayName)
                            DetailRow(title: "Executed", value: DateFormatter.localizedString(from: log.timestamp, dateStyle: .medium, timeStyle: .long))
                            DetailRow(title: "Completed", value: log.completed ? "Yes" : "No")
                        }

                        if let notes = log.notes, !notes.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Notes")
                                    .font(.headline)

                                Text(notes)
                                    .font(.body)
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }

                        if let actionResults = log.actionResults, !actionResults.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Action Results")
                                    .font(.headline)

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(actionResults.keys.sorted()), id: \.self) { key in
                                        if let value = actionResults[key] {
                                            DetailRow(title: key, value: value)
                                        }
                                    }
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Execution Log")
            } else {
                EmptyStateView(
                    title: "No Log Selected",
                    subtitle: "Select an execution log to view its details",
                    systemImage: "doc.text.circle"
                )
            }
        }
    }
}

#Preview {
    ExecutionLogDetailView(log: ExecutionLog(
        routineId: "preview",
        completed: true,
        notes: "Eye care reminder completed successfully",
        actionResults: [
            "notification": "sent successfully",
            "sound": "played"
        ]
    ))
}