import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let searchText: String
    @Binding var selectedId: Int64?

    @State private var hoveredScheduleId: Int64?

    var filteredSchedules: [Schedule] {
        if searchText.isEmpty {
            return viewModel.schedules
        } else {
            return viewModel.schedules.filter { schedule in
                schedule.displayName.localizedCaseInsensitiveContains(searchText) ||
                (schedule.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }

    var body: some View {
        VStack {
            if filteredSchedules.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "No Schedules" : "No Matching Schedules",
                    subtitle: searchText.isEmpty ? "Create schedules to automate your routines" : "No schedules match your search",
                    systemImage: "calendar.badge.clock"
                )
            } else {
                List(filteredSchedules, id: \.scheduleId) { schedule in
                    ScheduleRowView(
                        schedule: schedule,
                        isSelected: selectedId == schedule.scheduleId,
                        isHovered: hoveredScheduleId == schedule.scheduleId,
                        onSelect: {
                            selectedId = schedule.scheduleId
                        }
                    )
                    .onHover { isHovered in
                        hoveredScheduleId = isHovered ? schedule.scheduleId : nil
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Schedules")
    }
}

struct ScheduleRowView: View {
    let schedule: Schedule
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

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
    ScheduleListView(
        viewModel: ScheduleViewModel(),
        searchText: "",
        selectedId: .constant(nil)
    )
}