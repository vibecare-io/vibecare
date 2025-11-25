import SwiftUI
import Logging
import Combine
import VCStubs
import SwiftProtobuf

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var schedules: [Schedule] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(label: "com.vibecare.schedule-viewmodel")
    private let scheduleService = ScheduleService()
    private let actionService = ActionService()
    private var cancellables = Set<AnyCancellable>()

    // Current routine context
    private var currentRoutineId: String?

    init() {
        // Listen for profile changes
        NotificationCenter.default.publisher(for: .profileChanged)
            .compactMap { $0.object as? Profile }
            .sink { [weak self] profile in
                Task { [weak self] in
                    await self?.loadSchedules(for: profile.id)
                }
            }
            .store(in: &cancellables)

        // Listen for schedule triggered events to refresh and update "Next:" timer
        NotificationCenter.default.publisher(for: .scheduleTriggered)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refreshData()
                }
            }
            .store(in: &cancellables)
    }


    // MARK: - Data Loading

    func loadSchedules(for profileId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            schedules = try await scheduleService.listAllSchedules(for: profileId)
            logger.info("Loaded \(schedules.count) schedules for profile \(profileId)")
        } catch {
            logger.error("Failed to load schedules: \(error)")
            errorMessage = "Failed to load schedules: \(error.localizedDescription)"
            schedules = []
        }

        isLoading = false
    }

    // Load schedules for a specific routine (Routine detail view)
    func loadSchedules(forRoutine routineId: String) async {
        currentRoutineId = routineId
        isLoading = true
        defer { isLoading = false }

        do {
            schedules = try await scheduleService.listSchedules(for: routineId)
            logger.info("Loaded \(schedules.count) schedules for routine \(routineId)")
        } catch {
            logger.error("Failed to load schedules: \(error)")
            errorMessage = "Failed to load schedules: \(error.localizedDescription)"
            schedules = []
        }
    }

    // Deprecated: Use loadSchedules(forRoutine:) instead
    func loadSchedulesForRoutine(_ routineId: String) async {
        await loadSchedules(forRoutine: routineId)
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadSchedules(for: currentProfile.id)
    }

    func manualRefresh() async {
        await refreshData()
    }

    // MARK: - Filtering and Search

    func filteredSchedules(searchText: String) -> [Schedule] {
        if searchText.isEmpty {
            return schedules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return schedules.filter { schedule in
            schedule.name.localizedCaseInsensitiveContains(searchText) ||
            schedule.notes.localizedCaseInsensitiveContains(searchText) ||
            schedule.displayName.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Schedule Operations

    func createSchedule(
        routineId: String,
        profileId: String,
        name: String,
        rrule: String,
        scheduleTimezone: String = TimeZone.current.identifier,
        dtstart: Date = Date(),
        notes: String = "",
        enabled: Bool = true,
        actionIDs: [String] = []
    ) async {
        do {
            let newSchedule = Schedule(
                profileId: profileId,
                routineId: routineId,
                name: name,
                rrule: rrule,
                scheduleTimezone: scheduleTimezone,
                dtstart: dtstart,
                notes: notes,
                enabled: enabled
            )

            let savedSchedule = try await scheduleService.createSchedule(
                id: newSchedule.id,
                profileId: profileId,
                routineId: newSchedule.routineId,
                name: newSchedule.name,
                rrule: newSchedule.rrule,
                scheduleTimezone: scheduleTimezone,
                dtstart: ISO8601DateFormatter().string(from: newSchedule.dtstart),
                exdates: newSchedule.exdates,
                notes: newSchedule.notes,
                enabled: newSchedule.enabled,
            )
            schedules.append(savedSchedule)

            logger.info("Created schedule: \(name)")
            StatusBarManager.shared.showSuccess("Schedule '\(name)' created")

        } catch {
            logger.error("Failed to create schedule: \(error)")
            errorMessage = "Failed to create schedule: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to create schedule")
        }
    }

    func createScheduleFromTemplate(
        routineId: String,
        profileId: String,
        templateName: String,
        customName: String? = nil
    ) async {
        guard let template = Schedule.createFromTemplate(
            templateName: templateName,
            profileId: profileId,
            routineId: routineId,
            name: customName
        ) else {
            errorMessage = "Invalid template: \(templateName)"
            StatusBarManager.shared.showError("Invalid template")
            return
        }

        await createSchedule(
            routineId: template.routineId,
            profileId: template.profileId,
            name: template.name,
            rrule: template.rrule,
            dtstart: template.dtstart,
            notes: template.notes,
            enabled: template.enabled
        )
    }

    func updateSchedule(_ schedule: Schedule) async {
        do {
            var updatedSchedule = schedule
            updatedSchedule.updatedAt = Date()

            let savedSchedule = try await scheduleService.updateSchedule(updatedSchedule)

            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                schedules[index] = savedSchedule
            }

            logger.info("Updated schedule: \(schedule.name)")
            StatusBarManager.shared.showSuccess("Schedule '\(schedule.name)' updated")

        } catch {
            logger.error("Failed to update schedule: \(error)")
            errorMessage = "Failed to update schedule: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to update schedule")
        }
    }

    func deleteSchedule(_ schedule: Schedule) async {
        do {
            try await scheduleService.deleteSchedule(id: schedule.id)

            schedules.removeAll { $0.id == schedule.id }

            logger.info("Deleted schedule: \(schedule.name)")
            StatusBarManager.shared.showSuccess("Schedule '\(schedule.name)' deleted")

        } catch {
            logger.error("Failed to delete schedule: \(error)")
            errorMessage = "Failed to delete schedule: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to delete schedule")
        }
    }

    func toggleScheduleEnabled(_ schedule: Schedule) async {
        var updatedSchedule = schedule
        updatedSchedule.enabled.toggle()
        await updateSchedule(updatedSchedule)
    }

    func duplicateSchedule(_ schedule: Schedule) async {
        let duplicatedSchedule = Schedule(
            profileId: schedule.profileId,
            routineId: schedule.routineId,
            name: "\(schedule.name) Copy",
            rrule: schedule.rrule,
            dtstart: schedule.dtstart,
            exdates: schedule.exdates,
            notes: schedule.notes,
            enabled: schedule.enabled
        )

        await createScheduleFromModel(duplicatedSchedule)
    }

    func testSchedule(_ schedule: Schedule) async {
        logger.info("Preview/dry-run for schedule: \(schedule.name)")

        do {
            // 1. Fetch action IDs for this schedule
            let actionIds = try await scheduleService.getScheduleActions(scheduleId: schedule.id)

            if actionIds.isEmpty {
                StatusBarManager.shared.showMessage("No actions configured for '\(schedule.name)'", type: .info)
                return
            }

            // 2. Fetch full action details
            var actions: [Action] = []
            for actionId in actionIds {
                if let action = try await actionService.getAction(id: actionId) {
                    actions.append(action)
                }
            }

            if actions.isEmpty {
                StatusBarManager.shared.showMessage("Could not load actions for '\(schedule.name)'", type: .info)
                return
            }

            // 3. Execute each action locally (no backend logging)
            logger.info("Executing \(actions.count) action(s) for preview")
            for action in actions {
                executeActionLocally(action, schedule: schedule)
            }

            StatusBarManager.shared.showSuccess("Previewed \(actions.count) action(s)")

        } catch {
            logger.error("Failed to preview schedule: \(error)")
            StatusBarManager.shared.showError("Failed to preview: \(error.localizedDescription)")
        }
    }

    /// Execute an action locally for preview/dry-run (no backend logging)
    private func executeActionLocally(_ action: Action, schedule: Schedule) {
        logger.info("Preview executing action: \(action.name) (type: \(action.type))")

        switch action.type {
        case .notification:
            // Create a mock event for the notification manager
            var mockEvent = VCScheduleTriggeredEvent()
            mockEvent.scheduleID = schedule.id
            mockEvent.scheduleName = schedule.name
            mockEvent.routineID = schedule.routineId
            mockEvent.routineName = schedule.name  // Use schedule name as fallback
            mockEvent.scheduledTime = Google_Protobuf_Timestamp(date: Date())

            NotificationManager.shared.executeAction(action, for: mockEvent)

        case .openLink:
            LinkHandler.shared.executeAction(action)

        case .playSound:
            logger.info("Preview: play_sound action (not yet implemented)")

        case .runScript:
            logger.info("Preview: run_script action (not yet implemented)")

        case .sendEmail:
            logger.info("Preview: send_email action (not yet implemented)")

        case .systemCommand:
            logger.info("Preview: system_command action (not yet implemented)")

        case .apiCall:
            logger.info("Preview: api_call action (not yet implemented)")

        case .logEntry:
            logger.info("Preview log entry: \(action.parameters["message"] ?? "No message")")
        }
    }

    private func createScheduleFromModel(_ schedule: Schedule) async {
        await createSchedule(
            routineId: schedule.routineId,
            profileId: schedule.profileId,
            name: schedule.name,
            rrule: schedule.rrule,
            dtstart: schedule.dtstart,
            notes: schedule.notes,
            enabled: schedule.enabled
        )
    }

    // MARK: - Schedule Templates

    func getAvailableTemplates() -> [String] {
        return RRule.templateNames
    }

    func getTemplateRule(for templateName: String) -> RRule? {
        return RRule.templates[templateName]
    }

    // MARK: - Schedule Validation

    func validateSchedule(
        name: String,
        rrule: String
    ) -> ScheduleValidationResult {
        // Validate name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return .invalid("Schedule name cannot be empty")
        }

        // Check for duplicate names within the same routine
        if schedules.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
            return .invalid("A schedule with this name already exists")
        }

        // Validate RRule string
        do {
            _ = try RRule.fromRRuleString(rrule)
        } catch {
            return .invalid("Invalid recurrence rule format")
        }

        return .valid
    }

    // MARK: - Statistics

    var enabledSchedulesCount: Int {
        schedules.filter { $0.enabled }.count
    }

    var disabledSchedulesCount: Int {
        schedules.filter { !$0.enabled }.count
    }

    var totalSchedulesCount: Int {
        schedules.count
    }

    var upcomingSchedules: [Schedule] {
        schedules
            .filter { $0.enabled && $0.nextExecution != nil }
            .sorted {
                guard let first = $0.nextExecution, let second = $1.nextExecution else { return false }
                return first < second
            }
            .prefix(5)
            .map { $0 }
    }


    // MARK: - Bulk Operations

    func pauseAllSchedules() async {
        let activeSchedules = schedules.filter { $0.enabled }

        for schedule in activeSchedules {
            var updatedSchedule = schedule
            updatedSchedule.enabled = false
            await updateSchedule(updatedSchedule)
        }

        StatusBarManager.shared.showSuccess("Paused \(activeSchedules.count) schedule(s)")
    }

    func resumeAllSchedules() async {
        let disabledSchedules = schedules.filter { !$0.enabled }

        for schedule in disabledSchedules {
            var updatedSchedule = schedule
            updatedSchedule.enabled = true
            await updateSchedule(updatedSchedule)
        }

        StatusBarManager.shared.showSuccess("Resumed \(disabledSchedules.count) schedule(s)")
    }
}

// MARK: - Supporting Types

enum ScheduleValidationResult {
    case valid
    case invalid(String)

    var isValid: Bool {
        switch self {
        case .valid:
            return true
        case .invalid:
            return false
        }
    }

    var errorMessage: String? {
        switch self {
        case .valid:
            return nil
        case .invalid(let message):
            return message
        }
    }
}
