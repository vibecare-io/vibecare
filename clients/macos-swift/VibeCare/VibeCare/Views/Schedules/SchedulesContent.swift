import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let searchText: String
    @Binding var selectedId: String?

    @State private var hoveredScheduleId: String?

    var filteredSchedules: [Schedule] {
        return viewModel.filteredSchedules(searchText: searchText)
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
                List(filteredSchedules, id: \.id) { schedule in
                    ScheduleRowSimpleView(
                        schedule: schedule,
                        onToggle: {
                            Task {
                                await viewModel.toggleScheduleEnabled(schedule)
                            }
                        }
                    )
                    .onHover { isHovered in
                        hoveredScheduleId = isHovered ? schedule.id : nil
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Schedules")
    }
}

// ScheduleRowView is now defined in Views/Schedules/ScheduleRowView.swift

#Preview {
    ScheduleListView(
        viewModel: ScheduleViewModel(),
        searchText: "",
        selectedId: .constant(nil)
    )
}