import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let searchText: String
    @Binding var selectedId: String?

    @State private var hoveredScheduleId: String?
    @State private var showDeleteAlert = false
    @State private var scheduleToDelete: Schedule?

    var filteredSchedules: [Schedule] {
        return viewModel.filteredSchedules(searchText: searchText)
    }

    var filteredPendingDeletionSchedules: [Schedule] {
        return viewModel.filteredPendingDeletionSchedules(searchText: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with counts
            headerView

            // Schedule list
            if filteredSchedules.isEmpty && filteredPendingDeletionSchedules.isEmpty {
                emptyStateView
            } else {
                sectionedScheduleListContent
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                let totalActive = filteredSchedules.count
                let totalDeleted = filteredPendingDeletionSchedules.count

                Text("\(totalActive) schedule\(totalActive != 1 ? "s" : "")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                if totalDeleted > 0 {
                    Text("\(totalDeleted) pending deletion")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status indicators
            HStack(spacing: 12) {
                StatusIndicator(
                    count: filteredSchedules.filter { $0.enabled }.count,
                    label: "Active",
                    color: .green
                )

                StatusIndicator(
                    count: filteredSchedules.filter { !$0.enabled }.count,
                    label: "Disabled",
                    color: .orange
                )

                if !filteredPendingDeletionSchedules.isEmpty {
                    StatusIndicator(
                        count: filteredPendingDeletionSchedules.count,
                        label: "Deleting",
                        color: .red
                    )
                }
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
                Text("No Schedules")
                    .font(.title3)
                    .fontWeight(.medium)

                Text(searchText.isEmpty ?
                     "Create your first schedule to automate routine execution" :
                     "No schedules match your search")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if searchText.isEmpty {
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

    // MARK: - Sectioned Schedule List Content

    private var sectionedScheduleListContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Active Schedules Section
                if !filteredSchedules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Active Schedules")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Spacer()

                            Text("\(filteredSchedules.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 16)

                        LazyVStack(spacing: 1) {
                            ForEach(filteredSchedules) { schedule in
                                ScheduleRowView(
                                    schedule: schedule,
                                    isSelected: selectedId == schedule.id,
                                    isHovered: hoveredScheduleId == schedule.id,
                                    showSyncStatus: true,
                                    syncStatus: viewModel.getSyncStatus(for: schedule.id),
                                    retryCount: viewModel.getRetryCount(for: schedule.id),
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
                                    }
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
                                        Label(schedule.enabled ? "Disable" : "Enable",
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
                        }
                        .padding(.horizontal, 8)
                    }
                }

                // Recently Deleted Section
                if !filteredPendingDeletionSchedules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recently Deleted")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(filteredPendingDeletionSchedules.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 16)

                        LazyVStack(spacing: 1) {
                            ForEach(filteredPendingDeletionSchedules) { schedule in
                                ScheduleRowView(
                                    schedule: schedule,
                                    isSelected: selectedId == schedule.id,
                                    isHovered: hoveredScheduleId == schedule.id,
                                    showSyncStatus: true,
                                    isPendingDeletion: true,
                                    syncStatus: viewModel.getSyncStatus(for: schedule.id),
                                    retryCount: viewModel.getRetryCount(for: schedule.id),
                                    onSelect: {
                                        selectedId = schedule.id
                                    },
                                    onToggleEnabled: {
                                        // Disabled for pending deletion
                                    },
                                    onDelete: {
                                        // Already pending deletion
                                    },
                                    onDuplicate: {
                                        // Disabled for pending deletion
                                    },
                                    onTest: {
                                        // Disabled for pending deletion
                                    }
                                )
                                .onHover { isHovered in
                                    hoveredScheduleId = isHovered ? schedule.id : nil
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable {
            await viewModel.manualRefresh()
        }
    }
}

// MARK: - Actions

extension ScheduleListView {
    private func createNewSchedule() {
        // Set selectedId to a special "new" value to trigger creation mode
        selectedId = "new-schedule"
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