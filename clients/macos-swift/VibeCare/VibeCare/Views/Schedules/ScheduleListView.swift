import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let searchText: String
    @Binding var showInspector: Bool

    var body: some View {
        VStack {
            if viewModel.schedules.isEmpty {
                EmptyStateView(
                    title: "No Schedules",
                    subtitle: "Create schedules to automate your routines",
                    systemImage: "calendar.badge.clock"
                )
            } else {
                List(viewModel.schedules, id: \.scheduleId) { schedule in
                    ScheduleRowView(schedule: schedule)
                }
            }
        }
        .navigationTitle("Schedules")
    }
}

struct ScheduleRowView: View {
    let schedule: Schedule

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.displayName)
                    .font(.headline)

                if let rrule = schedule.rrule {
                    Text(rrule.humanReadableDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing) {
                Circle()
                    .fill(schedule.enabled ? .green : .gray)
                    .frame(width: 8, height: 8)

                if let nextRun = schedule.nextExecution {
                    Text(nextRun, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ScheduleListView(
        viewModel: ScheduleViewModel(),
        searchText: "",
        showInspector: .constant(false)
    )
}