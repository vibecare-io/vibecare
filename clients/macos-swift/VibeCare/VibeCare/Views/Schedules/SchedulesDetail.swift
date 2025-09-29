import SwiftUI

struct ScheduleDetailView: View {
    let schedule: Schedule?
    let viewModel: ScheduleViewModel

    var body: some View {
        Group {
            if let schedule = schedule {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Schedule Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(schedule.displayName)
                                .font(.largeTitle)
                                .fontWeight(.bold)

                            if !schedule.notes.isEmpty {
                                Text(schedule.notes)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Schedule Details
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(title: "Status", value: schedule.enabled ? "Active" : "Inactive")

                            if let nextExecution = schedule.nextExecution {
                                DetailRow(title: "Next Execution", value: DateFormatter.localizedString(from: nextExecution, dateStyle: .medium, timeStyle: .short))
                            }

                            DetailRow(title: "Created", value: DateFormatter.localizedString(from: schedule.createdAt, dateStyle: .medium, timeStyle: .short))

                            if schedule.updatedAt != schedule.createdAt {
                                DetailRow(title: "Last Updated", value: DateFormatter.localizedString(from: schedule.updatedAt, dateStyle: .medium, timeStyle: .short))
                            }
                        }

                        Divider()

                        // Actions
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Actions")
                                .font(.headline)

                            if schedule.enabled {
                                Button("Pause Schedule") {
                                    // TODO: Implement pause functionality
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button("Resume Schedule") {
                                    // TODO: Implement resume functionality
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Schedule Details")
            } else {
                EmptyStateView(
                    title: "No Schedule Selected",
                    subtitle: "Select a schedule from the list to view its details",
                    systemImage: "calendar.circle"
                )
            }
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

#Preview {
    ScheduleDetailView(
        schedule: Schedule(
            routineId: "preview",
            name: "Eye Care Schedule",
            recurrenceJSON: "{\"freq\":\"MINUTELY\",\"interval\":20}",
            notes: "20-20-20 rule for eye health"
        ),
        viewModel: ScheduleViewModel()
    )
}