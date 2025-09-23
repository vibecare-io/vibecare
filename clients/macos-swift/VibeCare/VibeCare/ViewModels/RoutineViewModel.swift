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

    init() {
        // Load sample data initially
        loadSampleData()

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
            // Simulate API call - replace with actual RoutineService call
            try await Task.sleep(nanoseconds: 500_000_000)

            let sampleActions = Action.samples(for: profileId)
            let sampleRoutines = Routine.samples(for: profileId, with: sampleActions)

            routines = sampleRoutines
            logger.info("Loaded \(routines.count) routines for profile: \(profileId)")

        } catch {
            logger.error("Failed to load routines: \(error)")
            errorMessage = "Failed to load routines: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadRoutines(for: currentProfile.id)
    }

    private func loadSampleData() {
        let profileId = "sample-profile"
        let sampleActions = Action.samples(for: profileId)
        routines = Routine.samples(for: profileId, with: sampleActions)
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
        actionIds: [String],
        enabled: Bool = true
    ) async {
        guard let profileId = AppState.shared.currentProfile?.id else { return }

        isLoading = true

        do {
            // Simulate API call
            try await Task.sleep(nanoseconds: 300_000_000)

            var newRoutine = Routine(
                profileId: profileId,
                name: name,
                description: description,
                actionIds: actionIds,
                enabled: enabled
            )

            newRoutine.updateMetadata(category: category)

            routines.append(newRoutine)
            logger.info("Created routine: \(name)")

        } catch {
            logger.error("Failed to create routine: \(error)")
            errorMessage = "Failed to create routine: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func updateRoutine(_ routine: Routine) async {
        isLoading = true

        do {
            // Simulate API call
            try await Task.sleep(nanoseconds: 300_000_000)

            if let index = routines.firstIndex(where: { $0.id == routine.id }) {
                var updatedRoutine = routine
                updatedRoutine.updatedAt = Date()
                routines[index] = updatedRoutine
                logger.info("Updated routine: \(routine.name)")
            }

        } catch {
            logger.error("Failed to update routine: \(error)")
            errorMessage = "Failed to update routine: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func deleteRoutine(_ routine: Routine) async {
        isLoading = true

        do {
            // Simulate API call
            try await Task.sleep(nanoseconds: 300_000_000)

            routines.removeAll { $0.id == routine.id }
            logger.info("Deleted routine: \(routine.name)")

        } catch {
            logger.error("Failed to delete routine: \(error)")
            errorMessage = "Failed to delete routine: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func toggleRoutineEnabled(_ routine: Routine) async {
        var updatedRoutine = routine
        updatedRoutine.enabled.toggle()
        await updateRoutine(updatedRoutine)
    }

    func duplicateRoutine(_ routine: Routine) async {
        guard let profileId = AppState.shared.currentProfile?.id else { return }

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

        // Simulate routine execution
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            // Update last execution time
            var updatedRoutine = routine
            updatedRoutine.lastExecutedAt = Date()
            await updateRoutine(updatedRoutine)

            logger.info("Routine test completed: \(routine.name)")

            // Show success notification
            await showTestNotification(for: routine)

        } catch {
            logger.error("Failed to test routine: \(error)")
            errorMessage = "Failed to test routine: \(error.localizedDescription)"
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
