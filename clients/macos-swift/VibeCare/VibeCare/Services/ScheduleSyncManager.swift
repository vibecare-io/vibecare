import Foundation
import Logging
import Combine
import SwiftUI

@MainActor
class ScheduleSyncManager: ObservableObject {
    static let shared = ScheduleSyncManager()

    @Published var isSyncing = false
    @Published var lastSyncTime: Date?
    @Published var syncErrors: [String] = []

    private let logger = Logger(label: "com.vibecare.schedule-sync")
    private let localStorage = ScheduleLocalStorage.shared
    private var scheduleService: ScheduleService?
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

    func initialize(with scheduleService: ScheduleService) {
        self.scheduleService = scheduleService
        logger.info("ScheduleSyncManager initialized with service")
    }

    func triggerSync() {
        Task {
            await performSync()
        }
    }

    func syncSchedule(_ schedule: Schedule) {
        Task {
            await syncSingleSchedule(schedule)
        }
    }

    // MARK: - Sync Operations

    private func performSync() async {
        guard let scheduleService = scheduleService else {
            logger.warning("ScheduleService not available, skipping sync")
            StatusBarManager.shared.offlineMode()
            return
        }

        guard !isSyncing else {
            logger.info("Schedule sync already in progress, skipping")
            return
        }

        isSyncing = true
        syncErrors.removeAll()

        logger.info("Starting schedule sync")

        do {
            // Get schedules that need syncing
            let schedulesNeedingSync = try localStorage.getSchedulesNeedingSync()
            let schedulesNeedingDeletion = try localStorage.getSchedulesNeedingDeletion()

            if schedulesNeedingSync.isEmpty && schedulesNeedingDeletion.isEmpty {
                logger.info("No schedules need syncing or deletion")
                isSyncing = false
                lastSyncTime = Date()
                StatusBarManager.shared.syncCompleted(count: 0)
                return
            }

            logger.info("Found \(schedulesNeedingSync.count) schedules needing sync, \(schedulesNeedingDeletion.count) needing deletion")
            StatusBarManager.shared.syncInProgress()

            var successCount = 0

            // Process regular sync schedules
            for schedule in schedulesNeedingSync {
                do {
                    await syncSingleSchedule(schedule, using: scheduleService)
                    successCount += 1
                } catch {
                    logger.error("Failed to sync schedule \(schedule.name): \(error)")
                    syncErrors.append("Failed to sync '\(schedule.name)': \(error.localizedDescription)")
                }
            }

            // Process deletion schedules
            for schedule in schedulesNeedingDeletion {
                do {
                    try await syncScheduleDeletion(schedule, using: scheduleService)
                    successCount += 1
                } catch {
                    logger.error("Failed to delete schedule \(schedule.name): \(error)")
                    syncErrors.append("Failed to delete '\(schedule.name)': \(error.localizedDescription)")
                }
            }

            lastSyncTime = Date()
            let totalSchedules = schedulesNeedingSync.count + schedulesNeedingDeletion.count
            logger.info("Schedule sync completed: \(successCount)/\(totalSchedules) successful")

            if syncErrors.isEmpty {
                StatusBarManager.shared.syncCompleted(count: successCount)
            } else {
                StatusBarManager.shared.syncFailed("Some schedules failed to sync")
            }

        } catch {
            logger.error("Schedule sync failed: \(error)")
            syncErrors.append(error.localizedDescription)
            StatusBarManager.shared.syncFailed(error.localizedDescription)
        }

        isSyncing = false
    }

    private func syncSingleSchedule(_ schedule: Schedule, using service: ScheduleService? = nil) async {
        let scheduleService = service ?? self.scheduleService
        guard let scheduleService = scheduleService else {
            logger.warning("ScheduleService not available for syncing schedule: \(schedule.name)")
            return
        }

        let syncStatus = localStorage.getSyncStatus(for: schedule.id) ?? .localOnly

        do {
            switch syncStatus {
            case .localOnly:
                await syncNewSchedule(schedule, using: scheduleService)
            case .pendingSync:
                await syncUpdatedSchedule(schedule, using: scheduleService)
            case .syncFailed:
                await retrySyncSchedule(schedule, using: scheduleService)
            case .synced, .conflict:
                // No action needed for synced schedules or conflicts (handle conflicts separately)
                break
            case .pendingDelete:
                // Deletions are handled separately in performSync
                break
            }
        } catch {
            logger.error("Failed to sync schedule \(schedule.name): \(error)")
            try? localStorage.updateSyncStatus(scheduleId: schedule.id, status: .syncFailed)
        }
    }

    private func syncNewSchedule(_ schedule: Schedule, using service: ScheduleService) async {
        logger.info("Syncing new schedule: \(schedule.name)")

        do {
            let serverSchedule = try await service.createSchedule(
                id: schedule.id,  // Pass client-generated ID
                routineId: schedule.routineId,
                name: schedule.name,
                recurrenceJSON: schedule.recurrenceJSON,
                dtstart: ISO8601DateFormatter().string(from: schedule.dtstart),
                exdates: schedule.exdates,
                notes: schedule.notes,
                enabled: schedule.enabled
            )

            // Log ID verification
            if serverSchedule.id != schedule.id {
                logger.warning("Server returned different ID! Client: \(schedule.id), Server: \(serverSchedule.id)")
            } else {
                logger.info("Server accepted client ID: \(schedule.id)")
            }

            // Update local storage with server ID and mark as synced
            try localStorage.updateSyncStatus(scheduleId: schedule.id, status: .synced)
            logger.info("Successfully synced new schedule: \(schedule.name)")

        } catch {
            logger.error("Failed to sync new schedule: \(error)")
            try? localStorage.updateSyncStatus(scheduleId: schedule.id, status: .syncFailed)
            StatusBarManager.shared.routineSyncFailed(schedule.name)
        }
    }

    private func syncUpdatedSchedule(_ schedule: Schedule, using service: ScheduleService) async {
        logger.info("Syncing updated schedule: \(schedule.name)")

        do {
            _ = try await service.updateSchedule(schedule)
            try localStorage.updateSyncStatus(scheduleId: schedule.id, status: .synced)
            logger.info("Successfully synced updated schedule: \(schedule.name)")

        } catch {
            logger.error("Failed to sync updated schedule: \(error)")
            try? localStorage.updateSyncStatus(scheduleId: schedule.id, status: .syncFailed)
        }
    }

    private func retrySyncSchedule(_ schedule: Schedule, using service: ScheduleService) async {
        logger.info("Retrying sync for schedule: \(schedule.name)")

        // Determine if this is a new schedule or update based on server existence
        do {
            if let _ = try await service.getSchedule(id: schedule.id) {
                // Schedule exists on server, update it
                await syncUpdatedSchedule(schedule, using: service)
            } else {
                // Schedule doesn't exist on server, create it
                await syncNewSchedule(schedule, using: service)
            }
        } catch {
            logger.error("Failed to retry sync for schedule: \(error)")
            try? localStorage.updateSyncStatus(scheduleId: schedule.id, status: .syncFailed)
        }
    }

    private func syncScheduleDeletion(_ schedule: Schedule, using service: ScheduleService) async throws {
        logger.info("Syncing schedule deletion: \(schedule.name)")

        do {
            // Call backend to delete the schedule
            try await service.deleteSchedule(id: schedule.id)

            // Successfully deleted on server - now permanently delete locally
            try localStorage.permanentlyDeleteSchedule(id: schedule.id)
            logger.info("Successfully deleted schedule from server and local storage: \(schedule.name)")

        } catch {
            logger.error("Failed to delete schedule from server: \(error)")

            // Check if schedule doesn't exist on server (404) - consider it successful
            let errorMsg = error.localizedDescription.lowercased()
            if errorMsg.contains("not found") || errorMsg.contains("notfound") {
                logger.info("Schedule not found on server (already deleted), removing locally: \(schedule.name)")
                try? localStorage.permanentlyDeleteSchedule(id: schedule.id)
            } else {
                // Other error - keep in pending delete state for retry
                throw error
            }
        }
    }

    // MARK: - Pull Sync (Server to Local)

    func pullFromServer(routineId: String) async {
        guard let scheduleService = scheduleService else {
            logger.warning("ScheduleService not available for pull sync")
            return
        }

        logger.info("Pulling schedules from server for routine: \(routineId)")

        do {
            let serverSchedules = try await scheduleService.listSchedules(for: routineId)
            let localSchedules = try localStorage.listSchedules(for: routineId)
            let schedulesNeedingDeletion = try localStorage.getSchedulesNeedingDeletion()

            // Get all local schedule IDs (including those pending deletion)
            let localScheduleIds = Set(localSchedules.map { $0.id })
            let pendingDeleteIds = Set(schedulesNeedingDeletion.map { $0.id })
            let allLocalIds = localScheduleIds.union(pendingDeleteIds)

            // Find schedules that exist on server but not locally (and not pending deletion)
            let newServerSchedules = serverSchedules.filter { serverSchedule in
                !allLocalIds.contains(serverSchedule.id)
            }

            // Add new server schedules to local storage
            for schedule in newServerSchedules {
                _ = try localStorage.createSchedule(schedule)
                try localStorage.updateSyncStatus(scheduleId: schedule.id, status: .synced)
            }

            if !newServerSchedules.isEmpty {
                logger.info("Pulled \(newServerSchedules.count) new schedules from server")
            }

            // Log if we skipped any server schedules due to pending local deletion
            let skippedDueToDeletion = serverSchedules.filter { pendingDeleteIds.contains($0.id) }
            if !skippedDueToDeletion.isEmpty {
                logger.info("Skipped \(skippedDueToDeletion.count) server schedules due to pending local deletion")
            }

            // TODO: Handle conflict resolution for schedules that exist both locally and on server
            // with different update times

        } catch {
            logger.error("Failed to pull schedules from server: \(error)")
        }
    }

    // MARK: - Conflict Resolution

    private func detectConflicts(localSchedules: [Schedule], serverSchedules: [Schedule]) -> [ScheduleConflict] {
        var conflicts: [ScheduleConflict] = []

        let serverScheduleMap = Dictionary(uniqueKeysWithValues: serverSchedules.map { ($0.id, $0) })

        for localSchedule in localSchedules {
            if let serverSchedule = serverScheduleMap[localSchedule.id] {
                // Check if there's a conflict (different update times and content)
                if localSchedule.updatedAt != serverSchedule.updatedAt &&
                   (localSchedule.name != serverSchedule.name ||
                    localSchedule.recurrenceJSON != serverSchedule.recurrenceJSON ||
                    localSchedule.enabled != serverSchedule.enabled) {

                    conflicts.append(ScheduleConflict(
                        scheduleId: localSchedule.id,
                        localVersion: localSchedule,
                        serverVersion: serverSchedule
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

    func getSyncStatistics() async -> ScheduleSyncStatistics {
        do {
            let stats = try localStorage.getSyncStatistics()
            return ScheduleSyncStatistics(
                totalSchedules: stats.values.reduce(0, +),
                syncedSchedules: stats[.synced] ?? 0,
                pendingSyncSchedules: stats[.pendingSync] ?? 0,
                localOnlySchedules: stats[.localOnly] ?? 0,
                failedSyncSchedules: stats[.syncFailed] ?? 0,
                conflictSchedules: stats[.conflict] ?? 0,
                pendingDeleteSchedules: stats[.pendingDelete] ?? 0,
                lastSyncTime: lastSyncTime,
                isSyncing: isSyncing
            )
        } catch {
            logger.error("Failed to get schedule sync statistics: \(error)")
            return ScheduleSyncStatistics()
        }
    }

    // Timer will be automatically invalidated when the object is deallocated
}

// MARK: - Supporting Types

struct ScheduleConflict {
    let scheduleId: String
    let localVersion: Schedule
    let serverVersion: Schedule
}

struct ScheduleSyncStatistics {
    let totalSchedules: Int
    let syncedSchedules: Int
    let pendingSyncSchedules: Int
    let localOnlySchedules: Int
    let failedSyncSchedules: Int
    let conflictSchedules: Int
    let pendingDeleteSchedules: Int
    let lastSyncTime: Date?
    let isSyncing: Bool

    init(
        totalSchedules: Int = 0,
        syncedSchedules: Int = 0,
        pendingSyncSchedules: Int = 0,
        localOnlySchedules: Int = 0,
        failedSyncSchedules: Int = 0,
        conflictSchedules: Int = 0,
        pendingDeleteSchedules: Int = 0,
        lastSyncTime: Date? = nil,
        isSyncing: Bool = false
    ) {
        self.totalSchedules = totalSchedules
        self.syncedSchedules = syncedSchedules
        self.pendingSyncSchedules = pendingSyncSchedules
        self.localOnlySchedules = localOnlySchedules
        self.failedSyncSchedules = failedSyncSchedules
        self.conflictSchedules = conflictSchedules
        self.pendingDeleteSchedules = pendingDeleteSchedules
        self.lastSyncTime = lastSyncTime
        self.isSyncing = isSyncing
    }
}