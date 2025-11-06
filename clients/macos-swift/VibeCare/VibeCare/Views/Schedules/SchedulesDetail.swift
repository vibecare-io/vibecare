import SwiftUI
import OpenTelemetryApi

// Context for action editing sheet presentation
struct ActionEditContext: Identifiable {
    let id = UUID()
    let actionCard: ScheduleActionCard
    let isCreating: Bool
    let profileId: String
    let schedule: Schedule
}

struct ScheduleDetailView: View {
    let schedule: Schedule?
    @ObservedObject var viewModel: ScheduleViewModel
    let isCreating: Bool
    let onCancel: (() -> Void)?

    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var showDuplicateSheet = false
    @State private var isTestingSchedule = false

    // Inline editing state
    @State private var scheduleName: String = ""
    @State private var scheduleNotes: String = ""
    @State private var scheduleEnabled: Bool = true
    @State private var schedulePriority: Priority = .none
    @State private var scheduleStartDate: Date = Date()
    @State private var scheduleRRule: String = ""
    @State private var scheduleExdates: [String] = []
    @State private var isSaving = false
    @State private var scheduleIdTracker: String = ""
    @State private var hasCreatedSchedule = false

    // RRule editing
    @State private var showRRuleEditor = false
    @State private var editingRRule: String = ""

    // Actions state
    @State private var actions: [Action] = []
    @State private var actionEditContext: ActionEditContext?

    // Services
    @StateObject private var actionService = ActionService()

    init(
        schedule: Schedule?,
        viewModel: ScheduleViewModel,
        isCreating: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        self.schedule = schedule
        self.viewModel = viewModel
        self.isCreating = isCreating
        self.onCancel = onCancel

        if let schedule = schedule {
            self._scheduleName = State(initialValue: schedule.name)
            self._scheduleNotes = State(initialValue: schedule.notes)
            self._scheduleEnabled = State(initialValue: schedule.enabled)
            self._schedulePriority = State(initialValue: schedule.priority)
            self._scheduleStartDate = State(initialValue: schedule.dtstart)
            self._scheduleRRule = State(initialValue: schedule.rrule)
            self._scheduleExdates = State(initialValue: schedule.exdates)
        } else {
            self._scheduleName = State(initialValue: "New Schedule")
            self._scheduleNotes = State(initialValue: "")
            self._scheduleEnabled = State(initialValue: true)
            self._schedulePriority = State(initialValue: .none)
            self._scheduleStartDate = State(initialValue: Date())
            self._scheduleRRule = State(initialValue: "FREQ=DAILY")
            self._scheduleExdates = State(initialValue: [])
        }
    }

    var body: some View {
        Group {
            if isCreating {
                scheduleCreationView
            } else if let schedule = schedule {
                scheduleDetailContent(schedule)
            } else {
                EmptyStateView(
                    title: "No Schedule Selected",
                    subtitle: "Select a schedule from the list to view its details",
                    systemImage: "calendar.circle"
                )
            }
        }
        .alert("Delete Schedule", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let schedule = schedule {
                    Task {
                        await viewModel.deleteSchedule(schedule)
                    }
                }
            }
        } message: {
            if let schedule = schedule {
                Text("Are you sure you want to delete '\(schedule.name)'? This action cannot be undone.")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let schedule = schedule {
                ScheduleFormView(viewModel: viewModel, editingSchedule: schedule)
            }
        }
        .sheet(isPresented: $showDuplicateSheet) {
            if let schedule = schedule {
                ScheduleFormView(viewModel: viewModel, duplicatingSchedule: schedule)
            }
        }
        .onChange(of: schedule?.id) { oldValue, newValue in
            handleScheduleIdChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: isCreating) { oldValue, newValue in
            handleIsCreatingChange(oldValue: oldValue, newValue: newValue)
        }
        .onAppear(perform: handleOnAppear)
    }

    // MARK: - Schedule Creation View

    private var scheduleCreationView: some View {
        ScheduleFormView(
            viewModel: viewModel,
            onCancel: onCancel
        )
    }

    // MARK: - Schedule Detail Content

    private func scheduleDetailContent(_ schedule: Schedule) -> some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Editable Title Section
                    editableTitleSection

                    // Status & Controls Section
                    statusAndControlsSection

                    Divider()

                    // Schedule Configuration Section
                    scheduleConfigurationSection

                    Divider()

                    // Editable Notes Section
                    editableNotesSection

                    Divider()

                    // Actions Section
                    actionsSection

                    Divider()

                    // Metadata Section
                    metadataSection

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
        .withTracing(viewName: "ScheduleDetailView")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                scheduleToolbarButtons(schedule)
            }
        }
    }

    // MARK: - Helper Functions

    private func handleScheduleIdChange(oldValue: String?, newValue: String?) {
        if oldValue != newValue {
            scheduleIdTracker = newValue ?? "new"
        }

        if let schedule = schedule {
            scheduleName = schedule.name
            scheduleNotes = schedule.notes
            scheduleEnabled = schedule.enabled
            schedulePriority = schedule.priority
            scheduleStartDate = schedule.dtstart
            scheduleRRule = schedule.rrule
            scheduleExdates = schedule.exdates
            loadActions()
        } else if isCreating {
            scheduleName = "New Schedule"
            scheduleNotes = ""
            scheduleEnabled = true
            schedulePriority = .none
            scheduleStartDate = Date()
            scheduleRRule = "FREQ=DAILY"
            scheduleExdates = []
        }
    }

    private func handleIsCreatingChange(oldValue: Bool, newValue: Bool) {
        if oldValue != newValue {
            scheduleIdTracker = schedule?.id ?? "new"
        }

        if newValue {
            scheduleName = "New Schedule"
            scheduleNotes = ""
            scheduleEnabled = true
            schedulePriority = .none
            scheduleStartDate = Date()
            scheduleRRule = "FREQ=DAILY"
            scheduleExdates = []
        } else if let schedule = schedule {
            scheduleName = schedule.name
            scheduleNotes = schedule.notes
            scheduleEnabled = schedule.enabled
            schedulePriority = schedule.priority
            scheduleStartDate = schedule.dtstart
            scheduleRRule = schedule.rrule
            scheduleExdates = schedule.exdates
        }
    }

    private func handleOnAppear() {
        scheduleIdTracker = schedule?.id ?? "new"
        loadActions()
    }

    // MARK: - Editable Title Section

    private var editableTitleSection: some View {
        EditableTitle(
            text: $scheduleName,
            placeholder: "Schedule name",
            autoFocus: isCreating,
            autoSelectText: "New Schedule"
        ) { newName in
            if isCreating {
                if newName != "New Schedule" &&
                   !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !hasCreatedSchedule {
                    Task {
                        await autoSaveNewSchedule()
                    }
                }
                scheduleName = newName
            } else if let schedule = schedule {
                Task {
                    await updateScheduleName(schedule, newName: newName)
                }
            }
        }
        .padding(.top, isCreating ? 0 : 8)
        .id(schedule?.id ?? "new")
    }

    // MARK: - Status & Controls Section

    private var statusAndControlsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                // Status indicator with inline toggle
                HStack(spacing: 12) {
                    Circle()
                        .fill(currentEnabled ? .green : .orange)
                        .frame(width: 12, height: 12)

                    Toggle("Enabled", isOn: Binding(
                        get: { currentEnabled },
                        set: { newValue in
                            scheduleEnabled = newValue
                            if let schedule = schedule {
                                Task {
                                    await updateScheduleEnabled(schedule, enabled: newValue)
                                }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .font(.subheadline)
                    .fontWeight(.medium)
                }

                Spacer()

                // Priority selector
                HStack(spacing: 8) {
                    Text("Priority:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { currentPriority },
                        set: { newValue in
                            schedulePriority = newValue
                            if let schedule = schedule {
                                Task {
                                    await updateSchedulePriority(schedule, priority: newValue)
                                }
                            }
                        }
                    )) {
                        ForEach(Priority.allCases, id: \.self) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }

            // Routine link
            if let schedule = schedule {
                RoutineLinkRow(routineId: schedule.routineId)
            }
        }
    }

    // MARK: - Schedule Configuration Section

    private var scheduleConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule Configuration")
                .font(.headline)
                .fontWeight(.semibold)

            // RRule Display
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recurrence Rule")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Button(action: {
                        withAnimation {
                            showRRuleEditor.toggle()
                        }
                        if showRRuleEditor {
                            editingRRule = scheduleRRule
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showRRuleEditor ? "chevron.up" : "chevron.down")
                                .font(.caption)
                            Text(showRRuleEditor ? "Collapse" : "Edit")
                                .font(.caption)
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                // RRule summary view
                RRuleSummaryView(rruleString: scheduleRRule, mode: .expanded)

                // Expandable RRule editor
                if showRRuleEditor {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RFC 5545 RRule Format")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: $editingRRule)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(Color(NSColor.textBackgroundColor))
                            .frame(minHeight: 100, maxHeight: 150)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )

                        HStack {
                            Spacer()

                            Button("Cancel") {
                                withAnimation {
                                    showRRuleEditor = false
                                }
                                editingRRule = scheduleRRule
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)

                            Button("Save") {
                                withAnimation {
                                    showRRuleEditor = false
                                }
                                scheduleRRule = editingRRule
                                if let schedule = schedule {
                                    Task {
                                        await updateScheduleRRule(schedule, rrule: editingRRule)
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Start Date/Time
            VStack(alignment: .leading, spacing: 8) {
                Text("Start Date & Time")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { currentStartDate },
                            set: { newValue in
                                scheduleStartDate = newValue
                                if let schedule = schedule {
                                    Task {
                                        await updateScheduleStartDate(schedule, startDate: newValue)
                                    }
                                }
                            }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)

                    Spacer()
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            // Excluded Dates
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Excluded Dates")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Button(action: {
                        // Add excluded date
                        let formatter = ISO8601DateFormatter()
                        let dateString = formatter.string(from: Date())
                        scheduleExdates.append(dateString)
                        if let schedule = schedule {
                            Task {
                                await updateScheduleExdates(schedule, exdates: scheduleExdates)
                            }
                        }
                    }) {
                        Image(systemName: "plus.circle")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if scheduleExdates.isEmpty {
                    Text("No excluded dates")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(scheduleExdates, id: \.self) { exdate in
                        HStack {
                            Text(formatExdate(exdate))
                                .font(.caption)

                            Spacer()

                            Button(action: {
                                scheduleExdates.removeAll { $0 == exdate }
                                if let schedule = schedule {
                                    Task {
                                        await updateScheduleExdates(schedule, exdates: scheduleExdates)
                                    }
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    // MARK: - Editable Notes Section

    private var editableNotesSection: some View {
        EditableDescription(
            text: $scheduleNotes,
            placeholder: "Add notes for this schedule",
            onSave: { newNotes in
                if isCreating {
                    scheduleNotes = newNotes
                    if !hasCreatedSchedule &&
                       scheduleName != "New Schedule" &&
                       !scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task {
                            await autoSaveNewSchedule()
                        }
                    } else if hasCreatedSchedule {
                        if let createdSchedule = viewModel.schedules.first(where: { $0.name == scheduleName }) {
                            var updatedSchedule = createdSchedule
                            updatedSchedule.notes = newNotes
                            Task {
                                await viewModel.updateSchedule(updatedSchedule)
                                StatusBarManager.shared.descriptionUpdated()
                            }
                        }
                    }
                } else if let schedule = schedule {
                    var updatedSchedule = schedule
                    updatedSchedule.notes = newNotes
                    Task {
                        await viewModel.updateSchedule(updatedSchedule)
                        StatusBarManager.shared.descriptionUpdated()
                    }
                }
            },
            forceEndEditing: scheduleIdTracker != (schedule?.id ?? "new")
        )
        .id(schedule?.id ?? "new")
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actions (\(actions.count))")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                // Add Action Dropdown Menu
                Menu {
                    ForEach(ActionType.allCases, id: \.self) { type in
                        Button {
                            openCreateActionSheet(type: type)
                        } label: {
                            Label(type.displayName, systemImage: type.iconName)
                        }
                    }
                } label: {
                    Label("Add Action", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            }

            if actions.isEmpty {
                Text("No actions configured. Add actions to trigger when this schedule fires.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(actions) { action in
                        CompactActionRow(
                            action: action,
                            onEdit: {
                                openEditActionSheet(action: action)
                            },
                            onDelete: {
                                deleteAction(action)
                            }
                        )
                    }
                }
            }
        }
        .sheet(item: $actionEditContext) { context in
            ActionEditSheet(
                profileId: context.profileId,
                schedule: context.schedule,
                actionCard: Binding(
                    get: { context.actionCard },
                    set: { _ in }
                ),
                isCreating: context.isCreating,
                onSave: {
                    loadActions()
                    actionEditContext = nil
                },
                onCancel: {
                    actionEditContext = nil
                }
            )
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Metadata")
                .font(.headline)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                if let schedule = schedule {
                    MetadataRow(
                        icon: "calendar.badge.plus",
                        title: "Created",
                        value: formatDate(schedule.createdAt)
                    )

                    if schedule.updatedAt != schedule.createdAt {
                        MetadataRow(
                            icon: "calendar.badge.clock",
                            title: "Updated",
                            value: formatDate(schedule.updatedAt)
                        )
                    }

                    if let lastExecution = schedule.lastExecution {
                        MetadataRow(
                            icon: "checkmark.circle",
                            title: "Last Execution",
                            value: formatRelativeDate(lastExecution)
                        )
                    } else {
                        MetadataRow(
                            icon: "checkmark.circle",
                            title: "Last Execution",
                            value: "Never"
                        )
                    }

                    if let nextExecution = schedule.nextExecution {
                        MetadataRow(
                            icon: "clock.arrow.circlepath",
                            title: "Next Run",
                            value: formatRelativeDate(nextExecution)
                        )
                    } else {
                        MetadataRow(
                            icon: "clock.arrow.circlepath",
                            title: "Next Run",
                            value: "Not scheduled"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Toolbar Buttons

    private func scheduleToolbarButtons(_ schedule: Schedule) -> some View {
        HStack {
            Button {
                isTestingSchedule = true
                Task {
                    await viewModel.testSchedule(schedule)
                    isTestingSchedule = false
                }
            } label: {
                Label("Test", systemImage: "play.circle")
            }
            .help("Test this schedule")
            .disabled(isTestingSchedule)

            Button {
                Task {
                    await viewModel.duplicateSchedule(schedule)
                }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .help("Duplicate schedule")

            Button {
                showDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete schedule")

            Button {
                showEditSheet = true
            } label: {
                Label("Advanced", systemImage: "gearshape")
            }
            .help("Advanced edit")
        }
    }

    // MARK: - Computed Properties

    private var currentEnabled: Bool {
        if isCreating {
            return scheduleEnabled
        } else {
            return schedule?.enabled ?? true
        }
    }

    private var currentPriority: Priority {
        if isCreating {
            return schedulePriority
        } else {
            return schedule?.priority ?? .none
        }
    }

    private var currentStartDate: Date {
        if isCreating {
            return scheduleStartDate
        } else {
            return schedule?.dtstart ?? Date()
        }
    }

    // MARK: - Update Methods

    private func updateScheduleName(_ schedule: Schedule, newName: String) async {
        var updatedSchedule = schedule
        updatedSchedule.name = newName
        await viewModel.updateSchedule(updatedSchedule)
        StatusBarManager.shared.titleUpdated()
    }

    private func updateScheduleEnabled(_ schedule: Schedule, enabled: Bool) async {
        var updatedSchedule = schedule
        updatedSchedule.enabled = enabled
        await viewModel.updateSchedule(updatedSchedule)
    }

    private func updateSchedulePriority(_ schedule: Schedule, priority: Priority) async {
        var updatedSchedule = schedule
        updatedSchedule.priority = priority
        await viewModel.updateSchedule(updatedSchedule)
    }

    private func updateScheduleStartDate(_ schedule: Schedule, startDate: Date) async {
        var updatedSchedule = schedule
        updatedSchedule.dtstart = startDate
        await viewModel.updateSchedule(updatedSchedule)
    }

    private func updateScheduleRRule(_ schedule: Schedule, rrule: String) async {
        var updatedSchedule = schedule
        updatedSchedule.rrule = rrule
        await viewModel.updateSchedule(updatedSchedule)
    }

    private func updateScheduleExdates(_ schedule: Schedule, exdates: [String]) async {
        var updatedSchedule = schedule
        updatedSchedule.exdates = exdates
        await viewModel.updateSchedule(updatedSchedule)
    }

    // MARK: - Actions Management

    private func loadActions() {
        guard let schedule = schedule else {
            print("DEBUG [loadActions]: No schedule")
            return
        }

        print("DEBUG [loadActions]: Loading actions for schedule '\(schedule.name)'")

        Task {
            do {
                // Fetch action IDs from schedule_actions join table
                let scheduleService = ScheduleService()
                let actionIDs = try await scheduleService.getScheduleActions(scheduleId: schedule.id)

                print("DEBUG [loadActions]: Found \(actionIDs.count) action IDs")

                var loadedActions: [Action] = []
                for actionID in actionIDs {
                    print("DEBUG [loadActions]: Fetching action \(actionID)...")
                    if let action = try await actionService.getAction(id: actionID) {
                        print("DEBUG [loadActions]: Loaded action \(action.id) of type \(action.type.displayName)")
                        loadedActions.append(action)
                    } else {
                        print("DEBUG [loadActions]: Action \(actionID) returned nil")
                    }
                }

                await MainActor.run {
                    actions = loadedActions
                    print("DEBUG [loadActions]: Set actions array to \(loadedActions.count) items")
                }
            } catch {
                print("ERROR [loadActions]: \(error)")
                await MainActor.run {
                    actions = []
                }
            }
        }
    }

    private func openCreateActionSheet(type: ActionType) {
        guard let schedule = schedule, let profileId = AppState.shared.currentProfile?.id else {
            return
        }

        actionEditContext = ActionEditContext(
            actionCard: ScheduleActionCard(type: type),
            isCreating: true,
            profileId: profileId,
            schedule: schedule
        )
    }

    private func openEditActionSheet(action: Action) {
        guard let schedule = schedule, let profileId = AppState.shared.currentProfile?.id else {
            return
        }

        actionEditContext = ActionEditContext(
            actionCard: ScheduleActionCard(
                id: action.id,
                type: action.type,
                parameters: action.parameters
            ),
            isCreating: false,
            profileId: profileId,
            schedule: schedule
        )
    }

    private func deleteAction(_ action: Action) {
        guard let schedule = schedule else { return }

        Task {
            do {
                // Remove from schedule_actions join table
                let scheduleService = ScheduleService()
                try await scheduleService.removeActionFromSchedule(scheduleId: schedule.id, actionId: action.id)

                // Optionally disable the action itself (soft delete)
                var updatedAction = action
                updatedAction.enabled = false
                _ = try await actionService.updateAction(updatedAction)

                // Reload actions
                await MainActor.run {
                    loadActions()
                }

                StatusBarManager.shared.showSuccess("Action removed from schedule")
            } catch {
                print("Error deleting action: \(error)")
                StatusBarManager.shared.showError("Failed to remove action")
            }
        }
    }

    // MARK: - Auto-save for New Schedule

    private func autoSaveNewSchedule() async {
        guard !scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !hasCreatedSchedule else { return }

        hasCreatedSchedule = true
        isSaving = true

        StatusBarManager.shared.savingInProgress()

        await viewModel.createSchedule(
            routineId: schedule?.routineId ?? "",
            profileId: schedule?.profileId ?? "",
            name: scheduleName.trimmingCharacters(in: .whitespacesAndNewlines),
            rrule: scheduleRRule,
            dtstart: scheduleStartDate,
            notes: scheduleNotes.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: scheduleEnabled,
            priority: schedulePriority
            // TODO: actions managed via schedule_actions join table
        )

        isSaving = false
        StatusBarManager.shared.showSuccess("Schedule '\(scheduleName)' created")
    }

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func formatRelativeDate(_ date: Date) -> String {
        return date.formatted(.relative(presentation: .named))
    }

    private func formatExdate(_ exdate: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: exdate) {
            return formatDate(date)
        }
        return exdate
    }
}

// MARK: - Supporting Views

struct RoutineLinkRow: View {
    let routineId: String
    @StateObject private var routineViewModel = RoutineViewModel()
    @State private var routineName: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundColor(.secondary)
                .font(.subheadline)

            Text("Routine:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let name = routineName {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            } else {
                Text(String(routineId.prefix(8)) + "...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("View") {
                // TODO: Navigate to routine detail
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .font(.caption)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(8)
        .onAppear {
            loadRoutineName()
        }
    }

    private func loadRoutineName() {
        guard let profileId = AppState.shared.currentProfile?.id else { return }
        Task {
            await routineViewModel.loadRoutines(for: profileId)
            if let routine = routineViewModel.routines.first(where: { $0.id == routineId }) {
                await MainActor.run {
                    routineName = routine.name
                }
            }
        }
    }
}

struct MetadataRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Schedule Form View (Placeholder)

struct ScheduleFormView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    var editingSchedule: Schedule?
    var duplicatingSchedule: Schedule?
    var onCancel: (() -> Void)?

    var body: some View {
        Text("Schedule Form - To be implemented")
            .frame(width: 600, height: 400)
    }
}

// MARK: - Preview

#Preview {
    Group {
        ScheduleDetailView(
            schedule: Schedule(
                profileId: "preview-profile",
                routineId: "preview",
                name: "Eye Care Schedule",
                rrule: "FREQ=MINUTELY;INTERVAL=20",
                notes: "20-20-20 rule for eye health"
            ),
            viewModel: ScheduleViewModel()
        )

        ScheduleDetailView(
            schedule: nil,
            viewModel: ScheduleViewModel()
        )

        ScheduleDetailView(
            schedule: nil,
            viewModel: ScheduleViewModel(),
            isCreating: true
        )
    }
}
