import SwiftUI

struct ScheduleListView: View {
  @ObservedObject var viewModel: ScheduleViewModel
  @ObservedObject var routineViewModel: RoutineViewModel
  @Binding var selectedId: String?
  @EnvironmentObject private var appState: AppState

  @State private var hoveredScheduleId: String?
  @State private var showDeleteAlert = false
  @State private var scheduleToDelete: Schedule?
  @State private var filterMode: FilterMode = .all
  @State private var expandedRoutineIds: Set<String> = []
  @State private var groupByRoutine: Bool = true
  @State private var showWizard = false
  @State private var searchText: String = ""

  // Multi-selection state
  @State private var selectedIds: Set<String> = []
  @State private var showBulkDeleteAlert: Bool = false

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

  var selectedSchedules: [Schedule] {
    displayedSchedules.filter { selectedIds.contains($0.id) }
  }

  var hasSelection: Bool {
    !selectedIds.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with counts and filters
      headerView

      // Bulk action bar (shown only when multiple items selected)
      if selectedIds.count > 1 {
        bulkActionBar
      }

      // Schedule list
      if displayedSchedules.isEmpty {
        emptyStateView
      } else {
        sectionedScheduleListContent
      }
    }
    .task {
      // Load schedules and routines when view appears
      if let profile = appState.currentProfile {
        async let loadSchedulesTask = viewModel.loadSchedules(for: profile.id)
        async let loadRoutinesTask = routineViewModel.loadRoutines(for: profile.id)

        _ = await (loadSchedulesTask, loadRoutinesTask)

        // Auto-expand all routines on first load when grouping is enabled
        if groupByRoutine && expandedRoutineIds.isEmpty {
          expandedRoutineIds = Set(routineViewModel.routines.map { $0.id })
        }
      }
    }
    .alert("Delete Schedule", isPresented: $showDeleteAlert) {
      Button("Cancel", role: .cancel) {}
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
    .alert(
      "Delete \(selectedIds.count) Schedule\(selectedIds.count == 1 ? "" : "s")",
      isPresented: $showBulkDeleteAlert
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task {
          await bulkDeleteSelectedSchedules()
        }
      }
    } message: {
      Text(
        "Are you sure you want to delete \(selectedIds.count) schedule\(selectedIds.count == 1 ? "" : "s")? This action cannot be undone."
      )
    }
    .sheet(isPresented: $showWizard) {
      ScheduleWizardView(
        routineViewModel: routineViewModel,
        scheduleViewModel: viewModel,
        onComplete: { scheduleId in
          showWizard = false
          // Select the newly created schedule
          selectedId = scheduleId
          // Refresh data
          Task {
            await viewModel.refreshData()
            await routineViewModel.refreshData()
          }
        },
        onCancel: {
          showWizard = false
        }
      )
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

        // Group by routine toggle
        Button {
          withAnimation(.easeInOut(duration: 0.25)) {
            groupByRoutine.toggle()
            // Auto-expand all routines when grouping is enabled
            if groupByRoutine {
              expandedRoutineIds = Set(routineViewModel.routines.map { $0.id })
            }
          }
        } label: {
          Image(systemName: groupByRoutine ? "square.grid.2x2.fill" : "square.grid.2x2")
            .foregroundColor(groupByRoutine ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(groupByRoutine ? "Show flat list" : "Group by routine")

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

      // Search bar
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundColor(.secondary)
        TextField("Schedule Name, Schedule Details, Routine...", text: $searchText)
          .textFieldStyle(.plain)
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(8)
      .background(Color(NSColor.textBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color(NSColor.controlBackgroundColor))
  }

  // MARK: - Bulk Action Bar

  private var bulkActionBar: some View {
    HStack(spacing: 12) {
      // Selection count
      Text("\(selectedIds.count) selected")
        .font(.subheadline)
        .fontWeight(.medium)

      Spacer()

      // Enable button
      Button {
        Task {
          await bulkEnableSelectedSchedules()
        }
      } label: {
        Label("Enable", systemImage: "play.circle")
      }
      .buttonStyle(.bordered)
      .tint(.green)

      // Disable button
      Button {
        Task {
          await bulkDisableSelectedSchedules()
        }
      } label: {
        Label("Disable", systemImage: "pause.circle")
      }
      .buttonStyle(.bordered)
      .tint(.orange)

      // Delete button
      Button {
        showBulkDeleteAlert = true
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .buttonStyle(.bordered)
      .tint(.red)

      // Clear selection button
      Button {
        withAnimation {
          selectedIds.removeAll()
        }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear selection")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color.accentColor.opacity(0.1))
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
    List(selection: $selectedIds) {
      if groupByRoutine {
        routineGroupedContent
      } else {
        flatListContent
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .refreshable {
      await viewModel.manualRefresh()
    }
    .onChange(of: selectedIds) { _, newValue in
      // Update single selection for detail view (use first selected if any)
      if let firstId = newValue.first, newValue.count == 1 {
        selectedId = firstId
      }
    }
  }

  // MARK: - Flat List Content

  @ViewBuilder
  private var flatListContent: some View {
    if filterMode == .all {
      if !activeSchedules.isEmpty {
        Section {
          ForEach(activeSchedules) { schedule in
            scheduleRow(for: schedule)
          }
        } header: {
          sectionHeader(title: "Active Schedules", count: activeSchedules.count)
        }
      }

      if !pausedSchedules.isEmpty {
        Section {
          ForEach(pausedSchedules) { schedule in
            scheduleRow(for: schedule)
          }
        } header: {
          sectionHeader(title: "Paused Schedules", count: pausedSchedules.count)
        }
      }
    } else {
      ForEach(displayedSchedules) { schedule in
        scheduleRow(for: schedule)
      }
    }
  }

  // MARK: - Section Header

  private func sectionHeader(title: String, count: Int) -> some View {
    HStack {
      Text(title)
        .font(.headline)
        .fontWeight(.semibold)
        .foregroundColor(.primary)
      Spacer()
      Text("\(count)")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }
    .padding(.horizontal, 8)
  }

  // MARK: - Routine Grouped Content

  @ViewBuilder
  private var routineGroupedContent: some View {
    ForEach(schedulesByRoutine.keys.sorted(), id: \.self) { routineId in
      if let schedulesInRoutine = schedulesByRoutine[routineId],
        !schedulesInRoutine.isEmpty
      {
        let routine = routineViewModel.routines.first { $0.id == routineId }
        let isExpanded = Binding(
          get: { expandedRoutineIds.contains(routineId) },
          set: { newValue in
            withAnimation(.easeInOut(duration: 0.25)) {
              if newValue {
                expandedRoutineIds.insert(routineId)
              } else {
                expandedRoutineIds.remove(routineId)
              }
            }
          }
        )

        Section(isExpanded: isExpanded) {
          ForEach(schedulesInRoutine) { schedule in
            scheduleRow(for: schedule)
          }
        } header: {
          routineHeader(routine: routine, schedules: schedulesInRoutine)
        }
      }
    }
  }

  // Group schedules by routine
  private var schedulesByRoutine: [String: [Schedule]] {
    Dictionary(grouping: displayedSchedules) { $0.routineId }
  }

  // MARK: - Routine Header

  private func routineHeader(routine: Routine?, schedules: [Schedule]) -> some View {
    let activeCount = schedules.filter { $0.enabled }.count

    return HStack(spacing: 12) {
      // Routine icon
      if let routine = routine {
        Image(systemName: routine.iconName)
          .font(.system(size: 16))
          .foregroundColor(Color(routine.color))
          .frame(width: 24, height: 24)
      } else {
        Image(systemName: "list.bullet")
          .font(.system(size: 16))
          .foregroundColor(.gray)
          .frame(width: 24, height: 24)
      }

      // Routine name
      Text(routine?.name ?? "Unknown Routine")
        .font(.headline)
        .fontWeight(.semibold)
        .foregroundColor(.primary)

      Spacer()

      // Active/total badge
      HStack(spacing: 4) {
        if activeCount > 0 {
          Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
        }

        Text("\(activeCount)/\(schedules.count)")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.secondary.opacity(0.1))
          .clipShape(Capsule())
      }
    }
  }

  // MARK: - Schedule Row

  private func scheduleRow(for schedule: Schedule) -> some View {
    ScheduleRowView(
      schedule: schedule,
      isSelected: selectedIds.contains(schedule.id),
      isHovered: hoveredScheduleId == schedule.id,
      onSelect: {
        // Update both single selection (for detail) and multi-selection set (for highlight)
        selectedId = schedule.id
        selectedIds = [schedule.id]
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
    .tag(schedule.id)
    .listRowSeparator(.hidden)
    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
    .listRowBackground(Color.clear)
    .onHover { isHovered in
      hoveredScheduleId = isHovered ? schedule.id : nil
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Delete", role: .destructive) {
        scheduleToDelete = schedule
        showDeleteAlert = true
      }

      Button {
        Task {
          await viewModel.toggleScheduleEnabled(schedule)
        }
      } label: {
        Label(
          schedule.enabled ? "Disable" : "Enable",
          systemImage: schedule.enabled ? "pause.circle" : "play.circle"
        )
      }
      .tint(schedule.enabled ? .orange : .green)
    }
    .swipeActions(edge: .leading) {
      Button {
        Task {
          await viewModel.toggleScheduleEnabled(schedule)
        }
      } label: {
        Label(
          schedule.enabled ? "Pause" : "Enable",
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

  // MARK: - Bulk Actions

  private func bulkEnableSelectedSchedules() async {
    for schedule in selectedSchedules where !schedule.enabled {
      var updatedSchedule = schedule
      updatedSchedule.enabled = true
      await viewModel.updateSchedule(updatedSchedule)
    }
    withAnimation {
      selectedIds.removeAll()
    }
    StatusBarManager.shared.showSuccess("Enabled \(selectedSchedules.count) schedule(s)")
  }

  private func bulkDisableSelectedSchedules() async {
    for schedule in selectedSchedules where schedule.enabled {
      var updatedSchedule = schedule
      updatedSchedule.enabled = false
      await viewModel.updateSchedule(updatedSchedule)
    }
    withAnimation {
      selectedIds.removeAll()
    }
    StatusBarManager.shared.showSuccess("Disabled \(selectedSchedules.count) schedule(s)")
  }

  private func bulkDeleteSelectedSchedules() async {
    let count = selectedSchedules.count
    for schedule in selectedSchedules {
      await viewModel.deleteSchedule(schedule)
    }
    withAnimation {
      selectedIds.removeAll()
    }
    StatusBarManager.shared.showSuccess("Deleted \(count) schedule(s)")
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
    // Show the wizard for template-based creation
    showWizard = true
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
            isSelected
              ? Color.clear
              : (isHovered ? Color.secondary.opacity(0.3) : Color.secondary.opacity(0.1)),
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
    routineViewModel: RoutineViewModel(),
    selectedId: .constant(nil)
  )
  .environmentObject(AppState.shared)
  .frame(width: 400, height: 600)
}
