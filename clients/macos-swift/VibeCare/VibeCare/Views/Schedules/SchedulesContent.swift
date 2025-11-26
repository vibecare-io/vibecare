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
      // Top row: Filter pills and action buttons
      HStack {
        // Filter buttons (moved up from below)
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
            isSelected: filterMode == .active,
            statusColor: .green
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              filterMode = .active
            }
          }

          FilterButton(
            title: "Paused",
            count: pausedSchedules.count,
            isSelected: filterMode == .paused,
            statusColor: .orange
          ) {
            withAnimation(.easeInOut(duration: 0.2)) {
              filterMode = .paused
            }
          }
        }

        Spacer()

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
    List {
      if groupByRoutine {
        routineGroupedContent
      } else {
        flatListContent
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .refreshable {
      await viewModel.manualRefresh()
    }
  }

  // MARK: - Flat Scroll Content

  @ViewBuilder
  private var flatScrollContent: some View {
    if filterMode == .all {
      if !activeSchedules.isEmpty {
        sectionHeader(title: "Active Schedules", count: activeSchedules.count)
          .padding(.top, 4)
        ForEach(activeSchedules) { schedule in
          scheduleRowForScroll(for: schedule)
        }
      }

      if !pausedSchedules.isEmpty {
        sectionHeader(title: "Paused Schedules", count: pausedSchedules.count)
          .padding(.top, 8)
        ForEach(pausedSchedules) { schedule in
          scheduleRowForScroll(for: schedule)
        }
      }
    } else {
      ForEach(displayedSchedules) { schedule in
        scheduleRowForScroll(for: schedule)
      }
    }
  }

  // MARK: - Flat List Content (Legacy)

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

  // MARK: - Routine Grouped Scroll Content

  @ViewBuilder
  private var routineGroupedScrollContent: some View {
    ForEach(schedulesByRoutine.keys.sorted(), id: \.self) { routineId in
      if let schedulesInRoutine = schedulesByRoutine[routineId],
        !schedulesInRoutine.isEmpty
      {
        let routine = routineViewModel.routines.first { $0.id == routineId }
        let isExpanded = expandedRoutineIds.contains(routineId)

        // Routine Header
        routineHeader(routine: routine, schedules: schedulesInRoutine)
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
              if isExpanded {
                expandedRoutineIds.remove(routineId)
              } else {
                expandedRoutineIds.insert(routineId)
              }
            }
          }
          .padding(.top, 4)

        // Schedules (shown when expanded)
        if isExpanded {
          ForEach(schedulesInRoutine) { schedule in
            scheduleRowForScroll(for: schedule)
          }
        }
      }
    }
  }

  // MARK: - Routine Grouped Content (Legacy List-based, kept for flatListContent)

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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 0, trailing: 8))
            .listRowBackground(Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
              isExpanded.wrappedValue.toggle()
            }
        }
        .listSectionSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
  }

  // Group schedules by routine
  private var schedulesByRoutine: [String: [Schedule]] {
    Dictionary(grouping: displayedSchedules) { $0.routineId }
  }

  // MARK: - Color Helper

  private func colorFromString(_ colorName: String) -> Color {
    switch colorName.lowercased() {
    case "blue": return .blue
    case "red": return .red
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    case "pink": return .pink
    case "yellow": return .yellow
    case "gray", "grey": return .gray
    case "brown": return .brown
    case "cyan": return .cyan
    case "indigo": return .indigo
    case "mint": return .mint
    case "teal": return .teal
    default: return .blue
    }
  }

  // MARK: - Routine Header

  private func routineHeader(routine: Routine?, schedules: [Schedule]) -> some View {
    let activeCount = schedules.filter { $0.enabled }.count
    let routineColor = colorFromString(routine?.color ?? "blue")
    let isExpanded = expandedRoutineIds.contains(routine?.id ?? "")

    return HStack(spacing: 6) {
      // Left accent bar (routine color)
      RoundedRectangle(cornerRadius: 2)
        .fill(routineColor)
        .frame(width: 3)

      // Chevron for expand/collapse
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 12)

      // Routine name
      Text(routine?.name ?? "Unknown Routine")
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundColor(.primary)

      Spacer()

      // Active/total count badge
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
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.1))
          .clipShape(Capsule())
      }
    }
    .padding(.vertical, 4)
    .padding(.trailing, 4)
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
    .listRowSeparator(.visible, edges: .bottom)
    .listRowSeparatorTint(Color.secondary.opacity(0.15))
    .listRowInsets(EdgeInsets(top: 1, leading: 24, bottom: 1, trailing: 8))
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

  // MARK: - Schedule Row for ScrollView

  private func scheduleRowForScroll(for schedule: Schedule) -> some View {
    VStack(spacing: 0) {
      ScheduleRowView(
        schedule: schedule,
        isSelected: selectedIds.contains(schedule.id),
        isHovered: hoveredScheduleId == schedule.id,
        onSelect: {
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
      .padding(.leading, 16)
      .padding(.vertical, 1)
      .onHover { isHovered in
        hoveredScheduleId = isHovered ? schedule.id : nil
      }

      // Separator line
      Divider()
        .padding(.leading, 24)
        .opacity(0.5)
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
  let statusColor: Color?
  let action: () -> Void

  @State private var isHovered = false

  init(title: String, count: Int, isSelected: Bool, statusColor: Color? = nil, action: @escaping () -> Void) {
    self.title = title
    self.count = count
    self.isSelected = isSelected
    self.statusColor = statusColor
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        // Status color dot (if provided)
        if let color = statusColor {
          Circle()
            .fill(color)
            .frame(width: 8, height: 8)
        }

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
      .contentShape(Rectangle())
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
