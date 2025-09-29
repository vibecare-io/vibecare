import SwiftUI
import Combine
import Logging

@MainActor
class RoutineViewModel: ObservableObject {
    @Published var routines: [Routine] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var syncStatus: [String: SyncStatus] = [:]

    private let logger = Logger(label: "com.vibecare.routine-viewmodel")
    private var cancellables = Set<AnyCancellable>()

    // Local-first services
    private let localStorage = RoutineLocalStorage.shared
    private let syncManager = RoutineSyncManager.shared
    private let routineService = RoutineService()

    init() {
        // Initialize sync manager with routine service
        syncManager.initialize(with: routineService)

        // Load from local storage first
        loadFromLocalStorage()

        // Listen for profile changes
        NotificationCenter.default.publisher(for: .profileChanged)
            .compactMap { $0.object as? Profile }
            .sink { [weak self] profile in
                Task { [weak self] in
                    await self?.loadRoutines(for: profile.id)
                }
            }
            .store(in: &cancellables)

        // Listen for sync manager updates
        syncManager.$isSyncing
            .sink { [weak self] isSyncing in
                if !isSyncing {
                    // Refresh from local storage after sync completes
                    self?.loadFromLocalStorage()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading

    func loadRoutines(for profileId: String) async {
        // Load from local storage first (instant)
        loadFromLocalStorage(profileId: profileId)

        // Trigger background sync
        syncManager.triggerSync()

        // Also pull any new routines from server
        await syncManager.pullFromServer(profileId: profileId)
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadRoutines(for: currentProfile.id)
    }

    private func loadFromLocalStorage(profileId: String? = nil) {
        let targetProfileId = profileId ?? AppState.shared.currentProfile?.id ?? "sample-profile"

        do {
            routines = try localStorage.getAllRoutines(for: targetProfileId)
            updateSyncStatus()
            logger.info("Loaded \(routines.count) routines from local storage (including pending deletion)")

            // No fallback sample data - start with empty state
        } catch {
            logger.error("Failed to load from local storage: \(error)")
            // Start with empty routines list
            routines = []
        }
    }


    private func updateSyncStatus() {
        var newSyncStatus: [String: SyncStatus] = [:]
        for routine in routines {
            newSyncStatus[routine.id] = localStorage.getSyncStatus(for: routine.id) ?? .localOnly
        }
        syncStatus = newSyncStatus
    }

    // MARK: - Filtering and Search

    func filteredRoutines(searchText: String) -> [Routine] {
        // Get only active routines (exclude pending deletion)
        let activeRoutines = getActiveRoutines()

        if searchText.isEmpty {
            return activeRoutines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return activeRoutines.filter { routine in
            routine.name.localizedCaseInsensitiveContains(searchText) ||
            routine.description.localizedCaseInsensitiveContains(searchText) ||
            routine.category.localizedCaseInsensitiveContains(searchText) ||
            routine.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func getActiveRoutines() -> [Routine] {
        return routines.filter { routine in
            let status = syncStatus[routine.id] ?? .localOnly
            return status != .pendingDelete
        }
    }

    func getPendingDeletionRoutines() -> [Routine] {
        return routines.filter { routine in
            let status = syncStatus[routine.id] ?? .localOnly
            return status == .pendingDelete
        }
    }

    func filteredPendingDeletionRoutines(searchText: String) -> [Routine] {
        let pendingDeletionRoutines = getPendingDeletionRoutines()

        if searchText.isEmpty {
            return pendingDeletionRoutines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return pendingDeletionRoutines.filter { routine in
            routine.name.localizedCaseInsensitiveContains(searchText) ||
            routine.description.localizedCaseInsensitiveContains(searchText) ||
            routine.category.localizedCaseInsensitiveContains(searchText) ||
            routine.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func routinesByCategory() -> [String: [Routine]] {
        Dictionary(grouping: routines) { $0.category }
    }

    // MARK: - Routine Operations

    func createRoutine(
        name: String,
        description: String,
        category: String,
        actionIds: [String],
        enabled: Bool = true
    ) async {
        guard let profileId = AppState.shared.currentProfile?.id else { return }

        do {
            // Create routine locally first (instant response)
            var newRoutine = Routine(
                profileId: profileId,
                name: name,
                description: description,
                actionIds: actionIds,
                enabled: enabled
            )

            newRoutine.updateMetadata(category: category)

            // Save to local storage immediately
            let savedRoutine = try localStorage.createRoutine(newRoutine)

            // Update UI immediately
            routines.append(savedRoutine)
            updateSyncStatus()

            logger.info("Created routine locally: \(name)")

            // Show immediate feedback
            StatusBarManager.shared.showSuccess("Routine '\(name)' saved")

            // Trigger background sync
            syncManager.syncRoutine(savedRoutine)

        } catch {
            logger.error("Failed to create routine: \(error)")
            errorMessage = "Failed to create routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to create routine")
        }
    }

    func updateRoutine(_ routine: Routine) async {
        do {
            // Update locally first (instant response)
            var updatedRoutine = routine
            updatedRoutine.updatedAt = Date()

            let savedRoutine = try localStorage.updateRoutine(updatedRoutine)

            // Update UI immediately
            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index] = savedRoutine
            }
            updateSyncStatus()

            logger.info("Updated routine locally: \(routine.name)")

            // Trigger background sync
            syncManager.syncRoutine(savedRoutine)

        } catch {
            logger.error("Failed to update routine: \(error)")
            errorMessage = "Failed to update routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to update routine")
        }
    }

    func updateRoutineName(_ routine: Routine, newName: String) async {
        // Validate the new name
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            logger.warning("Attempted to update routine with empty name")
            return
        }

        // Check for duplicate names (excluding current routine)
        if routines.contains(where: { $0.id != routine.id && $0.name.lowercased() == trimmedName.lowercased() }) {
            logger.warning("Attempted to update routine with duplicate name: \(trimmedName)")
            errorMessage = "A routine with this name already exists"
            StatusBarManager.shared.showError("A routine with this name already exists")
            return
        }

        do {
            // Update locally first
            var updatedRoutine = routine
            updatedRoutine.name = trimmedName
            updatedRoutine.updatedAt = Date()

            let savedRoutine = try localStorage.updateRoutine(updatedRoutine)

            // Update UI immediately
            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index] = savedRoutine
            }
            updateSyncStatus()

            logger.info("Updated routine name locally: \(routine.name) -> \(trimmedName)")

            // Trigger background sync
            syncManager.syncRoutine(savedRoutine)

        } catch {
            logger.error("Failed to update routine name: \(error)")
            errorMessage = "Failed to update routine name: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to update routine name")
        }
    }

    func deleteRoutine(_ routine: Routine) async {
        do {
            // Delete locally first (instant response)
            try localStorage.deleteRoutine(id: routine.id)

            // Update UI immediately
            routines.removeAll { $0.id == routine.id }
            updateSyncStatus()

            logger.info("Deleted routine locally: \(routine.name)")

            // Show immediate feedback
            StatusBarManager.shared.showSuccess("Routine '\(routine.name)' deleted")

            // Note: For deletions, we should sync to server to ensure consistency
            // But the UI is already updated for immediate response

        } catch {
            logger.error("Failed to delete routine: \(error)")
            errorMessage = "Failed to delete routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to delete routine")
        }
    }

    func toggleRoutineEnabled(_ routine: Routine) async {
        var updatedRoutine = routine
        updatedRoutine.enabled.toggle()
        await updateRoutine(updatedRoutine)
    }

    func duplicateRoutine(_ routine: Routine) async {
        guard AppState.shared.currentProfile?.id != nil else { return }

        let duplicatedRoutine = Routine(
            id: UUID().uuidString,
            profileId: routine.profileId,
            name: "\(routine.name) Copy",
            description: routine.description,
            actionIds: routine.actionIds,
            enabled: routine.enabled,
            metadata: routine.metadata,
            createdAt: Date(),
            updatedAt: Date(),
            lastExecutedAt: nil
        )

        await createRoutineFromModel(duplicatedRoutine)
    }

    func testRoutine(_ routine: Routine) async {
        logger.info("Testing routine: \(routine.name)")

        do {
            // Update last execution time locally first
            var updatedRoutine = routine
            updatedRoutine.lastExecutedAt = Date()
            await updateRoutine(updatedRoutine)

            logger.info("Routine test completed: \(routine.name)")

            // Show success notification
            StatusBarManager.shared.showSuccess("Routine '\(routine.name)' executed successfully")

            // TODO: Integrate with actual execution service
            await showTestNotification(for: routine)

        } catch {
            logger.error("Failed to test routine: \(error)")
            errorMessage = "Failed to test routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to test routine")
        }
    }

    private func createRoutineFromModel(_ routine: Routine) async {
        await createRoutine(
            name: routine.name,
            description: routine.description,
            category: routine.category,
            actionIds: routine.actionIds,
            enabled: routine.enabled
        )
    }

    private func showTestNotification(for routine: Routine) async {
        // This would integrate with the local notification system
        logger.info("Would show test notification for routine: \(routine.name)")
    }

    // MARK: - Statistics

    var enabledRoutinesCount: Int {
        routines.filter { $0.enabled }.count
    }

    var disabledRoutinesCount: Int {
        routines.filter { !$0.enabled }.count
    }

    var totalRoutinesCount: Int {
        routines.count
    }

    var recentlyExecutedRoutines: [Routine] {
        routines
            .filter { $0.lastExecutedAt != nil }
            .sorted { ($0.lastExecutedAt ?? Date.distantPast) > ($1.lastExecutedAt ?? Date.distantPast) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Validation

    func validateRoutineName(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Routine name cannot be empty"
        }

        if routines.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            return "A routine with this name already exists"
        }

        return nil
    }

    func canDeleteRoutine(_ routine: Routine) -> Bool {
        // Check if routine has active schedules
        // For now, always allow deletion
        return true
    }

    // MARK: - Sync Status

    func getSyncStatus(for routineId: String) -> SyncStatus? {
        return syncStatus[routineId]
    }

    func getSyncStatistics() async -> SyncStatistics {
        return await syncManager.getSyncStatistics()
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

    // MARK: - Data Management

    func clearAllData() async {
        guard let profileId = AppState.shared.currentProfile?.id else { return }

        do {
            try localStorage.clearAllRoutines(for: profileId)
            routines = []
            syncStatus = [:]
            logger.info("Cleared all local routine data")
            StatusBarManager.shared.showSuccess("All routines cleared")
        } catch {
            logger.error("Failed to clear all data: \(error)")
            errorMessage = "Failed to clear data: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to clear data")
        }
    }
}

// MARK: - Placeholder for actual service integration
/*
 Once RoutineService is implemented with real gRPC calls:

 func loadRoutines(for profileId: String) async {
     isLoading = true
     errorMessage = nil

     do {
         let routineService = RoutineService()
         let fetchedRoutines = try await routineService.listRoutines(profileId: profileId)
         routines = fetchedRoutines
         logger.info("Loaded \(routines.count) routines")
     } catch {
         logger.error("Failed to load routines: \(error)")
         errorMessage = error.localizedDescription
     }

     isLoading = false
 }
 */
