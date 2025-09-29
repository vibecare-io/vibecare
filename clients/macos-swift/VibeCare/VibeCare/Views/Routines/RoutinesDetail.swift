import SwiftUI

struct RoutineDetailView: View {
    let routine: Routine?
    @ObservedObject var viewModel: RoutineViewModel
    let isCreating: Bool
    var onCancel: (() -> Void)?

    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var showAddActionSheet = false
    @State private var routineName: String = ""
    @State private var routineDescription: String = ""
    @State private var routineCategory: String = "General"
    @State private var routineEnabled: Bool = true
    @State private var isSaving = false
    @State private var routineIdTracker: String = ""  // Track routine changes
    @State private var hasCreatedRoutine = false  // Track if we've already created the routine
    @State private var showAddScheduleSheet = false
    @StateObject private var scheduleViewModel = ScheduleViewModel()

    init(routine: Routine? = nil, viewModel: RoutineViewModel, isCreating: Bool = false, onCancel: (() -> Void)? = nil) {
        self.routine = routine
        self.viewModel = viewModel
        self.isCreating = isCreating
        self.onCancel = onCancel

        if let routine = routine {
            self._routineName = State(initialValue: routine.name)
            self._routineDescription = State(initialValue: routine.description)
            self._routineCategory = State(initialValue: routine.category)
            self._routineEnabled = State(initialValue: routine.enabled)
        } else {
            self._routineName = State(initialValue: "Your New Routine")
            self._routineDescription = State(initialValue: "")
            self._routineCategory = State(initialValue: "Health")
            self._routineEnabled = State(initialValue: true)
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                // Show "Create New Routine" header when creating
                if isCreating {
                    HStack {
                        Spacer()
                        Text("Create New Routine")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Spacer()

                        // Auto-save indicator
                        if isSaving {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Saving...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if hasCreatedRoutine {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Auto-saved")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .padding(.bottom, 8)
                }

                // Editable Title Header
                editableTitleSection

                // Status and Category
                statusSection

                // Description
                descriptionSection

                // Actions
                actionsSection

                // Schedules (only for existing routines)
                if !isCreating {
                    schedulesSection
                }

                // Execution History (only for existing routines)
                if !isCreating {
                    executionHistorySection
                }

                    Spacer(minLength: 40)
                }
                .padding(24)
            }

            // Status bar at the bottom
            VStack {
                Spacer()
                StatusBarView()
            }
        }
        .onChange(of: routine?.id) { oldValue, newValue in
            // Track the change for forcing edit end
            if oldValue != newValue {
                routineIdTracker = newValue ?? "new"
            }

            // Update local state when routine changes
            if let routine = routine {
                routineName = routine.name
                routineDescription = routine.description
                routineCategory = routine.category
                routineEnabled = routine.enabled
            } else if isCreating {
                // Reset to default values for new routine
                routineName = "Your New Routine"
                routineDescription = ""
                routineCategory = "Health"
                routineEnabled = true
            }
        }
        .onChange(of: isCreating) { oldValue, newValue in
            // Track the change
            if oldValue != newValue {
                routineIdTracker = routine?.id ?? "new"
            }

            // Update state when switching between create and view modes
            if newValue {
                // Entering creation mode
                routineName = "Your New Routine"
                routineDescription = ""
                routineCategory = "Health"
                routineEnabled = true
            } else if let routine = routine {
                // Switching back to view mode
                routineName = routine.name
                routineDescription = routine.description
                routineCategory = routine.category
                routineEnabled = routine.enabled
            }
        }
        .onAppear {
            // Initialize the tracker
            routineIdTracker = routine?.id ?? "new"
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isCreating {
                    // Creating mode toolbar - only show Cancel button
                    Button("Cancel") {
                        onCancel?()
                    }
                } else if let routine = routine {
                    // Viewing mode toolbar
                    Button {
                        Task {
                            await viewModel.testRoutine(routine)
                        }
                    } label: {
                        Label("Test", systemImage: "play.circle")
                    }
                    .help("Test this routine")

                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .help("Edit routine")

                    Menu {
                        Button {
                            Task {
                                await viewModel.duplicateRoutine(routine)
                            }
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }

                        Button {
                            Task {
                                await viewModel.toggleRoutineEnabled(routine)
                            }
                        } label: {
                            Label(routine.enabled ? "Disable" : "Enable",
                                  systemImage: routine.enabled ? "pause.circle" : "play.circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let routine = routine {
                Text("Edit form for \(routine.name)") // TODO: Implement edit form
            }
        }
        .sheet(isPresented: $showAddActionSheet) {
            Text("Add action form") // TODO: Implement add action form
        }
        .sheet(isPresented: $showAddScheduleSheet) {
            if let routine = routine {
                ScheduleEditView(
                    routineId: routine.id,
                    scheduleViewModel: scheduleViewModel,
                    isCreating: true
                ) {
                    showAddScheduleSheet = false
                }
            }
        }
        .alert("Delete Routine", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let routine = routine {
                    Task {
                        await viewModel.deleteRoutine(routine)
                    }
                }
            }
        } message: {
            if let routine = routine {
                Text("Are you sure you want to delete '\(routine.name)'? This action cannot be undone.")
            }
        }
    }


    // MARK: - Editable Title Section

    private var editableTitleSection: some View {
        EditableTitle(
            text: $routineName,
            autoFocus: isCreating  // Auto-focus when creating new routine
        ) { newName in
            if isCreating {
                // For new routines, auto-save when title changes from default
                if newName != "Your New Routine" &&
                   !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !hasCreatedRoutine {
                    Task {
                        await autoSaveNewRoutine()
                    }
                }
                routineName = newName
            } else if let routine = routine {
                // For existing routines, save to backend
                Task {
                    await viewModel.updateRoutineName(routine, newName: newName)
                    StatusBarManager.shared.titleUpdated()
                }
            }
        }
        .padding(.top, isCreating ? 0 : 8)
        .id(routine?.id ?? "new")  // Force view refresh when routine changes
    }

    // MARK: - Status Section

    private var statusSection: some View {
        HStack {
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(currentEnabled ? .green : .orange)
                    .frame(width: 12, height: 12)

                Text(currentEnabled ? "Active" : "Disabled")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(currentEnabled ? .green : .orange)
            }

            Spacer()

            // Category tag
            if !currentCategory.isEmpty {
                Text(currentCategory)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        EditableDescription(
            text: $routineDescription,
            placeholder: "Add a description for your routine",
            onSave: { newDescription in
                if isCreating {
                    // For new routines, also trigger auto-save if not yet created
                    routineDescription = newDescription
                    if !hasCreatedRoutine &&
                       routineName != "Your New Routine" &&
                       !routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task {
                            await autoSaveNewRoutine()
                        }
                    } else if hasCreatedRoutine {
                        // If routine already created, update it
                        if let createdRoutine = viewModel.routines.first(where: { $0.name == routineName }) {
                            var updatedRoutine = createdRoutine
                            updatedRoutine.description = newDescription
                            Task {
                                await viewModel.updateRoutine(updatedRoutine)
                                StatusBarManager.shared.descriptionUpdated()
                            }
                        }
                    }
                } else if let routine = routine {
                    // For existing routines, create updated routine and save
                    var updatedRoutine = routine
                    updatedRoutine.description = newDescription
                    Task {
                        await viewModel.updateRoutine(updatedRoutine)
                        StatusBarManager.shared.descriptionUpdated()
                    }
                }
            },
            forceEndEditing: routineIdTracker != (routine?.id ?? "new")
        )
        .id(routine?.id ?? "new")  // Force view refresh when routine changes
    }


    // MARK: - Schedules Section

    private var schedulesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Schedules (\(scheduleViewModel.totalSchedulesCount))")
                    .font(.headline)

                Spacer()

                FloatingActionButton(
                    title: "Add Schedule",
                    systemImage: "calendar.badge.plus"
                ) {
                    showAddScheduleSheet = true
                }
            }

            if scheduleViewModel.getActiveSchedules().isEmpty {
                EmptyStateView(
                    title: "No Schedules",
                    subtitle: "Add schedules to automatically trigger notifications for this routine",
                    systemImage: "calendar.circle"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(scheduleViewModel.getActiveSchedules()) { schedule in
                        ScheduleRowView(
                            schedule: schedule,
                            onEdit: { editSchedule(schedule) },
                            onDelete: { deleteSchedule(schedule) },
                            onToggle: { toggleSchedule(schedule) }
                        )
                    }
                }
            }
        }
        .onAppear {
            if let routine = routine {
                Task {
                    await scheduleViewModel.loadSchedules(for: routine.id)
                }
            }
        }
        .onChange(of: routine?.id) { oldValue, newValue in
            if let routineId = newValue {
                Task {
                    await scheduleViewModel.loadSchedules(for: routineId)
                }
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Actions (\(currentActionIds.count))")
                    .font(.headline)

                Spacer()

                FloatingActionButton(
                    title: "Add Action",
                    systemImage: "plus"
                ) {
                    showAddActionSheet = true
                }
            }

            if currentActionIds.isEmpty {
                EmptyStateView(
                    title: "No Actions",
                    subtitle: "Add actions to this routine to define what happens when it executes",
                    systemImage: "bolt.circle"
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(currentActionIds.indices, id: \.self) { index in
                        ActionPreviewCard(
                            actionId: currentActionIds[index],
                            index: index + 1
                        )
                    }
                }
            }
        }
    }

    // MARK: - Execution History Section

    private var executionHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Executions")
                    .font(.headline)

                Spacer()

                Button("View All") {
                    // Navigate to full execution history
                }
                .font(.caption)
            }

            // This would show actual execution logs
            // For now, show placeholder
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    ExecutionHistoryRow(
                        timestamp: Date().addingTimeInterval(TimeInterval(-index * 3600)),
                        success: index != 1,
                        notes: index == 1 ? "Action failed: Network timeout" : "Completed successfully"
                    )
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var currentEnabled: Bool {
        if isCreating {
            return routineEnabled
        } else {
            return routine?.enabled ?? true
        }
    }

    private var currentCategory: String {
        if isCreating {
            return routineCategory
        } else {
            return routine?.category ?? "General"
        }
    }

    private var currentActionIds: [String] {
        if isCreating {
            return [] // New routines start with no actions
        } else {
            return routine?.actionIds ?? []
        }
    }

    // MARK: - Schedule Actions

    private func editSchedule(_ schedule: Schedule) {
        // TODO: Implement edit schedule functionality
        // Could show the same ScheduleEditView but in edit mode
    }

    private func deleteSchedule(_ schedule: Schedule) {
        Task {
            await scheduleViewModel.deleteSchedule(schedule)
        }
    }

    private func toggleSchedule(_ schedule: Schedule) {
        Task {
            await scheduleViewModel.toggleScheduleEnabled(schedule)
        }
    }

    // MARK: - Actions

    private func autoSaveNewRoutine() async {
        guard !routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !hasCreatedRoutine else { return }  // Prevent duplicate creation

        hasCreatedRoutine = true
        isSaving = true

        // Show status
        StatusBarManager.shared.savingInProgress()

        await viewModel.createRoutine(
            name: routineName.trimmingCharacters(in: .whitespacesAndNewlines),
            description: routineDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            category: routineCategory,
            actionIds: [],
            enabled: routineEnabled
        )

        isSaving = false

        // Show success status
        StatusBarManager.shared.routineCreated(routineName)

        // Stay on the page so user can continue editing
        // The routine is now created and saved
    }
}

// MARK: - Supporting Views

struct MetadataItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct ActionPreviewCard: View {
    let actionId: String
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            // Step number
            Text("\(index)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Sample Action \(index)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Action description would go here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "bolt.circle.fill")
                .foregroundColor(.accentColor)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ExecutionHistoryRow: View {
    let timestamp: Date
    let success: Bool
    let notes: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(notes)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RoutineDetailView(
            routine: Routine(
                profileId: "preview-profile",
                name: "Sample Routine",
                description: "A preview routine for testing",
                actionIds: [],
                enabled: true
            ),
            viewModel: RoutineViewModel()
        )
    }
    .frame(width: 600, height: 800)
}