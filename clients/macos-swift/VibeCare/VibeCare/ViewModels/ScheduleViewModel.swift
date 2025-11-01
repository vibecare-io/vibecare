import SwiftUI
import Logging

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var schedules: [Schedule] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(label: "com.vibecare.schedule-viewmodel")
    private let scheduleService = ScheduleService()
    private let actionService = ActionService()

    // Current routine context
    private var currentRoutineId: String?

    init() {
        // Nothing to initialize
    }


    // MARK: - Data Loading

    func loadSchedules(for routineId: String) async {
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

    func refreshData() async {
        guard let routineId = currentRoutineId else { return }
        await loadSchedules(for: routineId)
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
        name: String,
        rrule: String,
        dtstart: Date = Date(),
        notes: String = "",
        enabled: Bool = true,
        priority: Priority = .none,
        actionIDs: [String] = []
    ) async {
        do {
            let newSchedule = Schedule(
                routineId: routineId,
                name: name,
                rrule: rrule,
                dtstart: dtstart,
                notes: notes,
                enabled: enabled,
                priority: priority,
                actionIDs: actionIDs
            )

            let savedSchedule = try await scheduleService.createSchedule(
                id: newSchedule.id,
                routineId: newSchedule.routineId,
                name: newSchedule.name,
                rrule: newSchedule.rrule,
                dtstart: ISO8601DateFormatter().string(from: newSchedule.dtstart),
                exdates: newSchedule.exdates,
                notes: newSchedule.notes,
                enabled: newSchedule.enabled,
                actionIDs: newSchedule.actionIDs
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
        templateName: String,
        customName: String? = nil
    ) async {
        guard let template = Schedule.createFromTemplate(
            templateName: templateName,
            routineId: routineId,
            name: customName
        ) else {
            errorMessage = "Invalid template: \(templateName)"
            StatusBarManager.shared.showError("Invalid template")
            return
        }

        await createSchedule(
            routineId: template.routineId,
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
        // TODO: Implement schedule testing
        logger.info("Testing schedule: \(schedule.name)")
        StatusBarManager.shared.showSuccess("Testing schedule '\(schedule.name)'")
    }

    private func createScheduleFromModel(_ schedule: Schedule) async {
        await createSchedule(
            routineId: schedule.routineId,
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
