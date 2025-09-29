import Foundation
import Logging
import Combine
import SwiftUI

@MainActor
class RoutineSyncManager: ObservableObject {
    static let shared = RoutineSyncManager()

    @Published var isSyncing = false
    @Published var lastSyncTime: Date?
    @Published var syncErrors: [String] = []

    private let logger = Logger(label: "com.vibecare.routine-sync")
    private let localStorage = RoutineLocalStorage.shared
    private var routineService: RoutineService?
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Sync configuration
    private let syncInterval: TimeInterval = 30.0 // 30 seconds
    private let maxRetryAttempts = 3
    private let backoffMultiplier: TimeInterval = 2.0

    private init() {
        setupPeriodicSync()
        observeAppStateChanges()
    }

    // MARK: - Public Interface

    func initialize(with routineService: RoutineService) {
        self.routineService = routineService
        logger.info("RoutineSyncManager initialized with service")
    }

    func triggerSync() {
        Task {
            await performSync()
        }
    }

    func syncRoutine(_ routine: Routine) {
        Task {
            await syncSingleRoutine(routine)
        }
    }

    // MARK: - Sync Operations

    private func performSync() async {
        guard let routineService = routineService else {
            logger.warning("RoutineService not available, skipping sync")
            StatusBarManager.shared.offlineMode()
            return
        }

        guard !isSyncing else {
            logger.info("Sync already in progress, skipping")
            return
        }

        isSyncing = true
        syncErrors.removeAll()

        logger.info("Starting routine sync")

        do {
            // Get routines that need syncing
            let routinesNeedingSync = try localStorage.getRoutinesNeedingSync()
            let routinesNeedingDeletion = try localStorage.getRoutinesNeedingDeletion()

            if routinesNeedingSync.isEmpty && routinesNeedingDeletion.isEmpty {
                logger.info("No routines need syncing or deletion")
                isSyncing = false
                lastSyncTime = Date()
                StatusBarManager.shared.syncCompleted(count: 0)
                return
            }

            logger.info("Found \(routinesNeedingSync.count) routines needing sync, \(routinesNeedingDeletion.count) needing deletion")
            StatusBarManager.shared.syncInProgress()

            var successCount = 0

            // Process regular sync routines
            for routine in routinesNeedingSync {
                do {
                    await syncSingleRoutine(routine, using: routineService)
                    successCount += 1
                } catch {
                    logger.error("Failed to sync routine \(routine.name): \(error)")
                    syncErrors.append("Failed to sync '\(routine.name)': \(error.localizedDescription)")
                }
            }

            // Process deletion routines
            for routine in routinesNeedingDeletion {
                do {
                    try await syncRoutineDeletion(routine, using: routineService)
                    successCount += 1
                } catch {
                    logger.error("Failed to delete routine \(routine.name): \(error)")
                    syncErrors.append("Failed to delete '\(routine.name)': \(error.localizedDescription)")
                }
            }

            lastSyncTime = Date()
            let totalRoutines = routinesNeedingSync.count + routinesNeedingDeletion.count
            logger.info("Sync completed: \(successCount)/\(totalRoutines) successful")

            if syncErrors.isEmpty {
                StatusBarManager.shared.syncCompleted(count: successCount)
            } else {
                StatusBarManager.shared.syncFailed("Some routines failed to sync")
            }

        } catch {
            logger.error("Sync failed: \(error)")
            syncErrors.append(error.localizedDescription)
            StatusBarManager.shared.syncFailed(error.localizedDescription)
        }

        isSyncing = false
    }

    private func syncSingleRoutine(_ routine: Routine, using service: RoutineService? = nil) async {
        let routineService = service ?? self.routineService
        guard let routineService = routineService else {
            logger.warning("RoutineService not available for syncing routine: \(routine.name)")
            return
        }

        let syncStatus = localStorage.getSyncStatus(for: routine.id) ?? .localOnly

        do {
            switch syncStatus {
            case .localOnly:
                await syncNewRoutine(routine, using: routineService)
            case .pendingSync:
                await syncUpdatedRoutine(routine, using: routineService)
            case .syncFailed:
                await retrySyncRoutine(routine, using: routineService)
            case .synced, .conflict:
                // No action needed for synced routines or conflicts (handle conflicts separately)
                break
            case .pendingDelete:
                // Deletions are handled separately in performSync
                break
            }
        } catch {
            logger.error("Failed to sync routine \(routine.name): \(error)")
            try? localStorage.updateSyncStatus(routineId: routine.id, status: .syncFailed)
        }
    }

    private func syncNewRoutine(_ routine: Routine, using service: RoutineService) async {
        logger.info("Syncing new routine: \(routine.name)")

        do {
            let serverRoutine = try await service.createRoutine(
                id: routine.id,  // Pass client-generated ID
                profileId: routine.profileId,
                name: routine.name,
                description: routine.description,
                actionIds: routine.actionIds,
                enabled: routine.enabled,
                metadata: routine.metadata
            )

            // Log ID verification
            if serverRoutine.id != routine.id {
                logger.warning("Server returned different ID! Client: \(routine.id), Server: \(serverRoutine.id)")
            } else {
                logger.info("Server accepted client ID: \(routine.id)")
            }

            // Update local storage with server ID and mark as synced
            try localStorage.updateSyncStatus(routineId: routine.id, status: .synced)
            logger.info("Successfully synced new routine: \(routine.name)")

            // Show success feedback (only for individual syncs, not batch)
            // StatusBarManager.shared.routineSynced(routine.name)

        } catch {
            logger.error("Failed to sync new routine: \(error)")
            try? localStorage.updateSyncStatus(routineId: routine.id, status: .syncFailed)
            StatusBarManager.shared.routineSyncFailed(routine.name)
        }
    }

    private func syncUpdatedRoutine(_ routine: Routine, using service: RoutineService) async {
        logger.info("Syncing updated routine: \(routine.name)")

        do {
            _ = try await service.updateRoutine(routine)
            try localStorage.updateSyncStatus(routineId: routine.id, status: .synced)
            logger.info("Successfully synced updated routine: \(routine.name)")

        } catch {
            logger.error("Failed to sync updated routine: \(error)")
            try? localStorage.updateSyncStatus(routineId: routine.id, status: .syncFailed)
        }
    }

    private func retrySyncRoutine(_ routine: Routine, using service: RoutineService) async {
        logger.info("Retrying sync for routine: \(routine.name)")

        // Determine if this is a new routine or update based on server existence
        do {
            if let _ = try await service.getRoutine(id: routine.id) {
                // Routine exists on server, update it
                await syncUpdatedRoutine(routine, using: service)
            } else {
                // Routine doesn't exist on server, create it
                await syncNewRoutine(routine, using: service)
            }
        } catch {
            logger.error("Failed to retry sync for routine: \(error)")
            try? localStorage.updateSyncStatus(routineId: routine.id, status: .syncFailed)
        }
    }

    private func syncRoutineDeletion(_ routine: Routine, using service: RoutineService) async throws {
        logger.info("Syncing routine deletion: \(routine.name)")

        do {
            // Call backend to delete the routine
            try await service.deleteRoutine(id: routine.id)

            // Successfully deleted on server - now permanently delete locally
            try localStorage.permanentlyDeleteRoutine(id: routine.id)
            logger.info("Successfully deleted routine from server and local storage: \(routine.name)")

        } catch {
            logger.error("Failed to delete routine from server: \(error)")

            // Check if routine doesn't exist on server (404) - consider it successful
            let errorMsg = error.localizedDescription.lowercased()
            if errorMsg.contains("not found") || errorMsg.contains("notfound") {
                logger.info("Routine not found on server (already deleted), removing locally: \(routine.name)")
                try? localStorage.permanentlyDeleteRoutine(id: routine.id)
            } else {
                // Other error - keep in pending delete state for retry
                throw error
            }
        }
    }

    // MARK: - Pull Sync (Server to Local)

    func pullFromServer(profileId: String) async {
        guard let routineService = routineService else {
            logger.warning("RoutineService not available for pull sync")
            return
        }

        logger.info("Pulling routines from server for profile: \(profileId)")

        do {
            let serverRoutines = try await routineService.listRoutines(for: profileId)
            let localRoutines = try localStorage.listRoutines(for: profileId)
            let routinesNeedingDeletion = try localStorage.getRoutinesNeedingDeletion()

            // Get all local routine IDs (including those pending deletion)
            let localRoutineIds = Set(localRoutines.map { $0.id })
            let pendingDeleteIds = Set(routinesNeedingDeletion.map { $0.id })
            let allLocalIds = localRoutineIds.union(pendingDeleteIds)

            // Find routines that exist on server but not locally (and not pending deletion)
            let newServerRoutines = serverRoutines.filter { serverRoutine in
                !allLocalIds.contains(serverRoutine.id)
            }

            // Add new server routines to local storage
            for routine in newServerRoutines {
                _ = try localStorage.createRoutine(routine)
                try localStorage.updateSyncStatus(routineId: routine.id, status: .synced)
            }

            if !newServerRoutines.isEmpty {
                logger.info("Pulled \(newServerRoutines.count) new routines from server")
            }

            // Log if we skipped any server routines due to pending local deletion
            let skippedDueToDeletion = serverRoutines.filter { pendingDeleteIds.contains($0.id) }
            if !skippedDueToDeletion.isEmpty {
                logger.info("Skipped \(skippedDueToDeletion.count) server routines due to pending local deletion")
            }

            // TODO: Handle conflict resolution for routines that exist both locally and on server
            // with different update times

        } catch {
            logger.error("Failed to pull routines from server: \(error)")
        }
    }

    // MARK: - Conflict Resolution

    private func detectConflicts(localRoutines: [Routine], serverRoutines: [Routine]) -> [RoutineConflict] {
        var conflicts: [RoutineConflict] = []

        let serverRoutineMap = Dictionary(uniqueKeysWithValues: serverRoutines.map { ($0.id, $0) })

        for localRoutine in localRoutines {
            if let serverRoutine = serverRoutineMap[localRoutine.id] {
                // Check if there's a conflict (different update times and content)
                if localRoutine.updatedAt != serverRoutine.updatedAt &&
                   (localRoutine.name != serverRoutine.name ||
                    localRoutine.description != serverRoutine.description ||
                    localRoutine.actionIds != serverRoutine.actionIds ||
                    localRoutine.enabled != serverRoutine.enabled) {

                    conflicts.append(RoutineConflict(
                        routineId: localRoutine.id,
                        localVersion: localRoutine,
                        serverVersion: serverRoutine
                    ))
                }
            }
        }

        return conflicts
    }

    // MARK: - Periodic Sync

    private func setupPeriodicSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performSync()
            }
        }
    }

    private func observeAppStateChanges() {
        // In SwiftUI, we'll handle app lifecycle through the App struct
        // For now, just rely on periodic sync
        // The main app can call triggerSync() when needed
    }

    // MARK: - Statistics

    func getSyncStatistics() async -> SyncStatistics {
        do {
            let stats = try localStorage.getSyncStatistics()
            return SyncStatistics(
                totalRoutines: stats.values.reduce(0, +),
                syncedRoutines: stats[.synced] ?? 0,
                pendingSyncRoutines: stats[.pendingSync] ?? 0,
                localOnlyRoutines: stats[.localOnly] ?? 0,
                failedSyncRoutines: stats[.syncFailed] ?? 0,
                conflictRoutines: stats[.conflict] ?? 0,
                pendingDeleteRoutines: stats[.pendingDelete] ?? 0,
                lastSyncTime: lastSyncTime,
                isSyncing: isSyncing
            )
        } catch {
            logger.error("Failed to get sync statistics: \(error)")
            return SyncStatistics()
        }
    }

    // Timer will be automatically invalidated when the object is deallocated
}

// MARK: - Supporting Types

struct RoutineConflict {
    let routineId: String
    let localVersion: Routine
    let serverVersion: Routine
}

struct SyncStatistics {
    let totalRoutines: Int
    let syncedRoutines: Int
    let pendingSyncRoutines: Int
    let localOnlyRoutines: Int
    let failedSyncRoutines: Int
    let conflictRoutines: Int
    let pendingDeleteRoutines: Int
    let lastSyncTime: Date?
    let isSyncing: Bool

    init(
        totalRoutines: Int = 0,
        syncedRoutines: Int = 0,
        pendingSyncRoutines: Int = 0,
        localOnlyRoutines: Int = 0,
        failedSyncRoutines: Int = 0,
        conflictRoutines: Int = 0,
        pendingDeleteRoutines: Int = 0,
        lastSyncTime: Date? = nil,
        isSyncing: Bool = false
    ) {
        self.totalRoutines = totalRoutines
        self.syncedRoutines = syncedRoutines
        self.pendingSyncRoutines = pendingSyncRoutines
        self.localOnlyRoutines = localOnlyRoutines
        self.failedSyncRoutines = failedSyncRoutines
        self.conflictRoutines = conflictRoutines
        self.pendingDeleteRoutines = pendingDeleteRoutines
        self.lastSyncTime = lastSyncTime
        self.isSyncing = isSyncing
    }
}