import SwiftUI
import Combine
import Logging

// MARK: - Notification Names
extension Notification.Name {
    static let scheduleDataChanged = Notification.Name("scheduleDataChanged")
    static let scheduleCreated = Notification.Name("scheduleCreated")
    static let scheduleUpdated = Notification.Name("scheduleUpdated")
    static let scheduleDeleted = Notification.Name("scheduleDeleted")
}

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var schedules: [Schedule] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var syncStatus: [String: SyncStatus] = [:]

    private let logger = Logger(label: "com.vibecare.schedule-viewmodel")
    private var cancellables = Set<AnyCancellable>()

    // Local-first services
    private let localStorage = ScheduleLocalStorage.shared
    private let syncManager = ScheduleSyncManager.shared
    private let scheduleService = ScheduleService()

    // Current routine context
    private var currentRoutineId: String?

    // Periodic refresh timer
    private var refreshTimer: Timer?

    init() {
        // Initialize sync manager with schedule service
        syncManager.initialize(with: scheduleService)

        // Listen for sync manager updates
        syncManager.$isSyncing
            .sink { [weak self] isSyncing in
                if !isSyncing {
                    // Refresh from local storage after sync completes
                    self?.loadFromLocalStorage()
                }
            }
            .store(in: &cancellables)

        // Listen for schedule data change notifications
        NotificationCenter.default.publisher(for: .scheduleDataChanged)
            .sink { [weak self] _ in
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .scheduleCreated)
            .sink { [weak self] _ in
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .scheduleUpdated)
            .sink { [weak self] _ in
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .scheduleDeleted)
            .sink { [weak self] _ in
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        // Listen for app lifecycle changes
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        // Listen for sync manager error changes (in case sync status affects display)
        syncManager.$syncErrors
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateSyncStatus()
                }
            }
            .store(in: &cancellables)

        // Listen for sync time changes to refresh data
        syncManager.$lastSyncTime
            .compactMap { $0 }
            .sink { [weak self] _ in
                // Refresh data when a sync completes
                self?.refreshAllData()
            }
            .store(in: &cancellables)

        // Setup periodic refresh (every 60 seconds)
        setupPeriodicRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Data Loading

    func loadSchedules(for routineId: String) async {
        currentRoutineId = routineId

        // Load from local storage first (instant)
        loadFromLocalStorage(routineId: routineId)

        // Trigger background sync
        syncManager.triggerSync()

        // Also pull any new schedules from server
        await syncManager.pullFromServer(routineId: routineId)
    }

    func loadAllSchedules(for profileId: String) async {
        // Load all schedules across all routines for a profile
        currentRoutineId = nil // Clear routine context

        // Load from local storage first (instant)
        loadAllSchedulesFromLocalStorage()

        // Trigger background sync for all routines
        syncManager.triggerSync()
    }

    func refreshData() async {
        guard let routineId = currentRoutineId else { return }
        await loadSchedules(for: routineId)
    }

    private func refreshAllData() {
        Task { @MainActor in
            if let routineId = currentRoutineId {
                // Refresh routine-specific schedules
                loadFromLocalStorage(routineId: routineId)
            } else {
                // Refresh all schedules across all routines
                loadAllSchedulesFromLocalStorage()
            }
        }
    }

    func forceRefresh() async {
        guard let profileId = getProfileId() else { return }
        await loadAllSchedules(for: profileId)
    }

    private func getProfileId() -> String? {
        // TODO: Get current profile ID from AppState or similar
        // For now, return nil - this should be injected or accessed via environment
        return nil
    }

    private func setupPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshAllData()
        }
    }

    private func loadFromLocalStorage(routineId: String? = nil) {
        let targetRoutineId = routineId ?? currentRoutineId ?? ""
        guard !targetRoutineId.isEmpty else { return }

        do {
            schedules = try localStorage.getAllSchedules(for: targetRoutineId)
            updateSyncStatus()
            logger.info("Loaded \(schedules.count) schedules from local storage (including pending deletion)")

        } catch {
            logger.error("Failed to load schedules from local storage: \(error)")
            schedules = []
        }
    }

    private func loadAllSchedulesFromLocalStorage() {
        do {
            schedules = try localStorage.getAllSchedulesAcrossAllRoutines()
            updateSyncStatus()
            logger.info("Loaded \(schedules.count) schedules across all routines from local storage (including pending deletion)")
        } catch {
            logger.error("Failed to load all schedules from local storage: \(error)")
            schedules = []
        }
    }

    private func updateSyncStatus() {
        var newSyncStatus: [String: SyncStatus] = [:]
        for schedule in schedules {
            newSyncStatus[schedule.id] = localStorage.getSyncStatus(for: schedule.id) ?? .localOnly
        }
        syncStatus = newSyncStatus
    }

    // MARK: - Filtering and Search

    func filteredSchedules(searchText: String) -> [Schedule] {
        // Get only active schedules (exclude pending deletion)
        let activeSchedules = getActiveSchedules()

        if searchText.isEmpty {
            return activeSchedules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return activeSchedules.filter { schedule in
            schedule.name.localizedCaseInsensitiveContains(searchText) ||
            schedule.notes.localizedCaseInsensitiveContains(searchText) ||
            schedule.displayName.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func getActiveSchedules() -> [Schedule] {
        return schedules.filter { schedule in
            let status = syncStatus[schedule.id] ?? .localOnly
            return status != .pendingDelete
        }
    }

    func getPendingDeletionSchedules() -> [Schedule] {
        return schedules.filter { schedule in
            let status = syncStatus[schedule.id] ?? .localOnly
            return status == .pendingDelete
        }
    }

    func filteredPendingDeletionSchedules(searchText: String) -> [Schedule] {
        let pendingDeletionSchedules = getPendingDeletionSchedules()

        if searchText.isEmpty {
            return pendingDeletionSchedules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return pendingDeletionSchedules.filter { schedule in
            schedule.name.localizedCaseInsensitiveContains(searchText) ||
            schedule.notes.localizedCaseInsensitiveContains(searchText) ||
            schedule.displayName.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Schedule Operations

    func createSchedule(
        routineId: String,
        name: String,
        recurrenceJSON: String,
        dtstart: Date = Date(),
        notes: String = "",
        enabled: Bool = true
    ) async {
        do {
            // Create schedule locally first (instant response)
            let newSchedule = Schedule(
                routineId: routineId,
                name: name,
                recurrenceJSON: recurrenceJSON,
                dtstart: dtstart,
                notes: notes,
                enabled: enabled
            )

            // Save to local storage immediately
            let savedSchedule = try localStorage.createSchedule(newSchedule)

            // Update UI immediately
            schedules.append(savedSchedule)
            updateSyncStatus()

            logger.info("Created schedule locally: \(name)")

            // Show immediate feedback
            StatusBarManager.shared.showSuccess("Schedule '\(name)' saved")

            // Trigger background sync
            syncManager.syncSchedule(savedSchedule)

            // Notify other views of the change
            NotificationCenter.default.post(name: .scheduleCreated, object: savedSchedule)

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
            recurrenceJSON: template.recurrenceJSON,
            dtstart: template.dtstart,
            notes: template.notes,
            enabled: template.enabled
        )
    }

    func updateSchedule(_ schedule: Schedule) async {
        do {
            // Update locally first (instant response)
            var updatedSchedule = schedule
            updatedSchedule.updatedAt = Date()

            let savedSchedule = try localStorage.updateSchedule(updatedSchedule)

            // Update UI immediately
            if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
                schedules[index] = savedSchedule
            }
            updateSyncStatus()

            logger.info("Updated schedule locally: \(schedule.name)")

            // Trigger background sync
            syncManager.syncSchedule(savedSchedule)

            // Notify other views of the change
            NotificationCenter.default.post(name: .scheduleUpdated, object: savedSchedule)

        } catch {
            logger.error("Failed to update schedule: \(error)")
            errorMessage = "Failed to update schedule: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to update schedule")
        }
    }

    func deleteSchedule(_ schedule: Schedule) async {
        do {
            // Delete locally first (instant response)
            try localStorage.deleteSchedule(id: schedule.id)

            // Update UI immediately - move to pending deletion
            updateSyncStatus()

            logger.info("Marked schedule for deletion locally: \(schedule.name)")

            // Show immediate feedback
            StatusBarManager.shared.showSuccess("Schedule '\(schedule.name)' deleted")

            // Notify other views of the change
            NotificationCenter.default.post(name: .scheduleDeleted, object: schedule)

            // Note: For deletions, we should sync to server to ensure consistency
            // But the UI is already updated for immediate response

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
            recurrenceJSON: schedule.recurrenceJSON,
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
            recurrenceJSON: schedule.recurrenceJSON,
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
        recurrenceJSON: String
    ) -> ScheduleValidationResult {
        // Validate name
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return .invalid("Schedule name cannot be empty")
        }

        // Check for duplicate names within the same routine
        if getActiveSchedules().contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
            return .invalid("A schedule with this name already exists")
        }

        // Validate RRule JSON
        do {
            _ = try RRule.fromJSON(recurrenceJSON)
        } catch {
            return .invalid("Invalid recurrence rule format")
        }

        return .valid
    }

    // MARK: - Statistics

    var enabledSchedulesCount: Int {
        getActiveSchedules().filter { $0.enabled }.count
    }

    var disabledSchedulesCount: Int {
        getActiveSchedules().filter { !$0.enabled }.count
    }

    var totalSchedulesCount: Int {
        getActiveSchedules().count
    }

    var upcomingSchedules: [Schedule] {
        getActiveSchedules()
            .filter { $0.enabled && $0.nextExecution != nil }
            .sorted {
                guard let first = $0.nextExecution, let second = $1.nextExecution else { return false }
                return first < second
            }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Sync Status

    func getSyncStatus(for scheduleId: String) -> SyncStatus? {
        return syncStatus[scheduleId]
    }

    func getSyncStatistics() async -> ScheduleSyncStatistics {
        return await syncManager.getSyncStatistics()
    }

    func getRetryCount(for scheduleId: String) -> Int {
        do {
            return try localStorage.getRetryCount(for: scheduleId)
        } catch {
            logger.error("Failed to get retry count for schedule \(scheduleId): \(error)")
            return 0
        }
    }

    func getSyncErrorHistory(for scheduleId: String) -> [SyncError] {
        do {
            return try localStorage.getSyncErrorHistory(for: scheduleId)
        } catch {
            logger.error("Failed to get sync error history for schedule \(scheduleId): \(error)")
            return []
        }
    }

    var hasPendingSync: Bool {
        return syncStatus.values.contains { status in
            status == .localOnly || status == .pendingSync || status == .syncFailed
        }
    }

    var isSyncing: Bool {
        return syncManager.isSyncing
    }

    func forceSyncAll() {
        syncManager.triggerSync()
    }

    func manualRefresh() async {
        isLoading = true
        defer { isLoading = false }

        // Clear any previous errors
        errorMessage = nil

        // Refresh from local storage immediately
        refreshAllData()

        // Also trigger a sync to get latest from server
        syncManager.triggerSync()

        logger.info("Manual refresh triggered")
        StatusBarManager.shared.showSuccess("Schedules refreshed")
    }

    // MARK: - Bulk Operations

    func pauseAllSchedules() async {
        let activeSchedules = getActiveSchedules().filter { $0.enabled }

        for schedule in activeSchedules {
            var updatedSchedule = schedule
            updatedSchedule.enabled = false
            await updateSchedule(updatedSchedule)
        }

        StatusBarManager.shared.showSuccess("Paused \(activeSchedules.count) schedule(s)")

        // Notify other views of the bulk change
        NotificationCenter.default.post(name: .scheduleDataChanged, object: nil)
    }

    func resumeAllSchedules() async {
        let disabledSchedules = getActiveSchedules().filter { !$0.enabled }

        for schedule in disabledSchedules {
            var updatedSchedule = schedule
            updatedSchedule.enabled = true
            await updateSchedule(updatedSchedule)
        }

        StatusBarManager.shared.showSuccess("Resumed \(disabledSchedules.count) schedule(s)")

        // Notify other views of the bulk change
        NotificationCenter.default.post(name: .scheduleDataChanged, object: nil)
    }

    // MARK: - Data Management

    func clearAllSchedules() async {
        guard let routineId = currentRoutineId else { return }

        do {
            try localStorage.clearAllSchedules(for: routineId)
            schedules = []
            syncStatus = [:]
            logger.info("Cleared all local schedule data for routine: \(routineId)")
            StatusBarManager.shared.showSuccess("All schedules cleared")

            // Notify other views of the data change
            NotificationCenter.default.post(name: .scheduleDataChanged, object: nil)
        } catch {
            logger.error("Failed to clear all schedule data: \(error)")
            errorMessage = "Failed to clear data: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to clear data")
        }
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
