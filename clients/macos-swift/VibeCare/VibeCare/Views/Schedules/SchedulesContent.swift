import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let searchText: String
    @Binding var selectedId: String?
    @EnvironmentObject private var appState: AppState

    @State private var hoveredScheduleId: String?
    @State private var showDeleteAlert = false
    @State private var scheduleToDelete: Schedule?
    @State private var filterMode: FilterMode = .all

    var filteredSchedules: [Schedule] {
        return viewModel.filteredSchedules(searchText: searchText)
    }

    var activeSchedules: [Schedule] {
        filteredSchedules.filter { $0.enabled }
    }

    var pausedSchedules: [Schedule] {
        filteredSchedules.filter { !$0.enabled }
    }

    var displayedSchedules: [Schedule] {
        switch filterMode {
        case .all:
            return filteredSchedules
        case .active:
            return activeSchedules
        case .paused:
            return pausedSchedules
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with counts and filters
            headerView

            // Schedule list
            if displayedSchedules.isEmpty {
                emptyStateView
            } else {
                sectionedScheduleListContent
            }
        }
        .task {
            // Load schedules when view appears
            if let profile = appState.currentProfile {
                await viewModel.loadSchedules(for: profile.id)
            }
        }
        .alert("Delete Schedule", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let schedule = scheduleToDelete {
                    Task {
                        await viewModel.deleteSchedule(schedule)
                    }
                }
            }
        } message: {
            if let schedule = scheduleToDelete {
                Text("Are you sure you want to delete '\(schedule.name)'? This action cannot be undone.")
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: Count and action buttons
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    let totalCount = displayedSchedules.count

                    Text("\(totalCount) schedule\(totalCount != 1 ? "s" : "")")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }

                Spacer()

                // Status indicators
                HStack(spacing: 12) {
                    StatusIndicator(
                        count: activeSchedules.count,
                        label: "Active",
                        color: .green
                    )

                    StatusIndicator(
                        count: pausedSchedules.count,
                        label: "Paused",
                        color: .orange
                    )
                }

                // Refresh button
                Button {
                    Task {
                        await viewModel.manualRefresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .help("Refresh schedules")

                // Create new schedule button
                FloatingActionButtonSmall(systemImage: "plus") {
                    createNewSchedule()
                }
            }

            // Filter buttons
            HStack(spacing: 8) {
                FilterButton(
                    title: "All",
                    count: filteredSchedules.count,
                    isSelected: filterMode == .all
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        filterMode = .all
                    }
                }

                FilterButton(
                    title: "Active",
                    count: activeSchedules.count,
                    isSelected: filterMode == .active
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        filterMode = .active
                    }
                }

                FilterButton(
                    title: "Paused",
                    count: pausedSchedules.count,
                    isSelected: filterMode == .paused
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        filterMode = .paused
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text(emptyStateTitle)
                    .font(.title3)
                    .fontWeight(.medium)

                Text(emptyStateMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if shouldShowCreateButton {
                Button("Create Schedule") {
                    createNewSchedule()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty {
            return "No Schedules Found"
        }

        switch filterMode {
        case .all:
            return "No Schedules"
        case .active:
            return "No Active Schedules"
        case .paused:
            return "No Paused Schedules"
        }
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No schedules match your search '\(searchText)'"
        }

        switch filterMode {
        case .all:
            return "Create your first schedule to automate routine execution"
        case .active:
            return "All schedules are currently paused. Enable a schedule to see it here."
        case .paused:
            return "No schedules are paused. Great job staying active!"
        }
    }

    private var shouldShowCreateButton: Bool {
        searchText.isEmpty && filterMode == .all
    }

    // MARK: - Sectioned Schedule List Content

    private var sectionedScheduleListContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Show sections based on filter mode
                if filterMode == .all {
                    // Active Schedules Section
                    if !activeSchedules.isEmpty {
                        scheduleSection(
                            title: "Active Schedules",
                            schedules: activeSchedules,
                            emptyMessage: nil
                        )
                    }

                    // Paused Schedules Section
                    if !pausedSchedules.isEmpty {
                        scheduleSection(
                            title: "Paused Schedules",
                            schedules: pausedSchedules,
                            emptyMessage: nil
                        )
                    }
                } else {
                    // Single filtered section
                    scheduleSection(
                        title: filterMode == .active ? "Active Schedules" : "Paused Schedules",
                        schedules: displayedSchedules,
                        emptyMessage: nil
                    )
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable {
            await viewModel.manualRefresh()
        }
    }

    // MARK: - Schedule Section

    @ViewBuilder
    private func scheduleSection(
        title: String,
        schedules: [Schedule],
        emptyMessage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Text("\(schedules.count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)

            // Schedule rows
            if schedules.isEmpty, let message = emptyMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(schedules) { schedule in
                        scheduleRow(for: schedule)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Schedule Row

    private func scheduleRow(for schedule: Schedule) -> some View {
        ScheduleRowView(
            schedule: schedule,
            isSelected: selectedId == schedule.id,
            isHovered: hoveredScheduleId == schedule.id,
            onSelect: {
                selectedId = schedule.id
            },
            onToggleEnabled: {
                Task {
                    await viewModel.toggleScheduleEnabled(schedule)
                }
            },
            onDelete: {
                scheduleToDelete = schedule
                showDeleteAlert = true
            },
            onDuplicate: {
                Task {
                    await viewModel.duplicateSchedule(schedule)
                }
            },
            onTest: {
                Task {
                    await viewModel.testSchedule(schedule)
                }
            },
            routineName: getRoutineName(for: schedule)
        )
        .onHover { isHovered in
            hoveredScheduleId = isHovered ? schedule.id : nil
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Delete", role: .destructive) {
                scheduleToDelete = schedule
                showDeleteAlert = true
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Task {
                    await viewModel.toggleScheduleEnabled(schedule)
                }
            } label: {
                Label(schedule.enabled ? "Pause" : "Enable",
                      systemImage: schedule.enabled ? "pause.circle" : "play.circle")
            }
            .tint(schedule.enabled ? .orange : .green)

            Button {
                Task {
                    await viewModel.duplicateSchedule(schedule)
                }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .tint(.blue)
        }
    }

    // MARK: - Helper Methods

    private func getRoutineName(for schedule: Schedule) -> String? {
        // In a real implementation, this would fetch the routine name from RoutineViewModel
        // For now, return nil and let ScheduleRowView use the fallback
        return nil
    }
}

// MARK: - Filter Mode

extension ScheduleListView {
    enum FilterMode {
        case all
        case active
        case paused
    }
}

// MARK: - Actions

extension ScheduleListView {
    private func createNewSchedule() {
        // Set selectedId to a special "new" value to trigger creation mode
        selectedId = "new-schedule"
    }
}

// MARK: - Filter Button

struct FilterButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.white.opacity(0.3)
                            : Color.secondary.opacity(0.1)
                    )
                    .clipShape(Capsule())
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.clear : (isHovered ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.1)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ScheduleListView(
        viewModel: ScheduleViewModel(),
        searchText: "",
        selectedId: .constant(nil)
    )
    .frame(width: 400, height: 600)
}
