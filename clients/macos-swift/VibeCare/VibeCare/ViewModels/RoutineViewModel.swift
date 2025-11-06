import SwiftUI
import Combine
import Logging

@MainActor
class RoutineViewModel: ObservableObject {
    @Published var routines: [Routine] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(label: "com.vibecare.routine-viewmodel")
    private var cancellables = Set<AnyCancellable>()
    private let routineService = RoutineService()

    init() {
        // Listen for profile changes
        NotificationCenter.default.publisher(for: .profileChanged)
            .compactMap { $0.object as? Profile }
            .sink { [weak self] profile in
                Task { [weak self] in
                    await self?.loadRoutines(for: profile.id)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading

    func loadRoutines(for profileId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            routines = try await routineService.listRoutines(for: profileId)
            logger.info("Loaded \(routines.count) routines from server")
        } catch {
            logger.error("Failed to load routines: \(error)")
            errorMessage = "Failed to load routines: \(error.localizedDescription)"
            routines = []
        }

        isLoading = false
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadRoutines(for: currentProfile.id)
    }

    // MARK: - Filtering and Search

    func filteredRoutines(searchText: String) -> [Routine] {
        if searchText.isEmpty {
            return routines.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return routines.filter { routine in
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
        enabled: Bool = true
    ) async {
        guard let profileId = AppState.shared.currentProfile?.id else { return }

        isLoading = true
        errorMessage = nil

        do {
            var newRoutine = Routine(
                profileId: profileId,
                name: name,
                description: description,
                enabled: enabled
            )

            newRoutine.updateMetadata(category: category)

            let createdRoutine = try await routineService.createRoutine(
                id: newRoutine.id,
                profileId: profileId,
                name: newRoutine.name,
                description: newRoutine.description,
                enabled: newRoutine.enabled,
                metadata: newRoutine.metadata
            )
            routines.append(createdRoutine)

            logger.info("Created routine: \(name)")
            StatusBarManager.shared.showSuccess("Routine '\(name)' created")

        } catch {
            logger.error("Failed to create routine: \(error)")
            errorMessage = "Failed to create routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to create routine")
        }

        isLoading = false
    }

    func updateRoutine(_ routine: Routine) async {
        isLoading = true
        errorMessage = nil

        do {
            var updatedRoutine = routine
            updatedRoutine.updatedAt = Date()

            let savedRoutine = try await routineService.updateRoutine(updatedRoutine)

            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                routines[index] = savedRoutine
            }

            logger.info("Updated routine: \(routine.name)")
            StatusBarManager.shared.showSuccess("Routine '\(routine.name)' updated")

        } catch {
            logger.error("Failed to update routine: \(error)")
            errorMessage = "Failed to update routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to update routine")
        }

        isLoading = false
    }

    func updateRoutineName(_ routine: Routine, newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            logger.warning("Attempted to update routine with empty name")
            return
        }

        if routines.contains(where: { $0.id != routine.id && $0.name.lowercased() == trimmedName.lowercased() }) {
            logger.warning("Attempted to update routine with duplicate name: \(trimmedName)")
            errorMessage = "A routine with this name already exists"
            StatusBarManager.shared.showError("A routine with this name already exists")
            return
        }

        var updatedRoutine = routine
        updatedRoutine.name = trimmedName
        await updateRoutine(updatedRoutine)
    }

    func deleteRoutine(_ routine: Routine) async {
        isLoading = true
        errorMessage = nil

        do {
            try await routineService.deleteRoutine(id: routine.id)
            routines.removeAll { $0.id == routine.id }

            logger.info("Deleted routine: \(routine.name)")
            StatusBarManager.shared.showSuccess("Routine '\(routine.name)' deleted")

        } catch {
            logger.error("Failed to delete routine: \(error)")
            errorMessage = "Failed to delete routine: \(error.localizedDescription)"
            StatusBarManager.shared.showError("Failed to delete routine")
        }

        isLoading = false
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

}
