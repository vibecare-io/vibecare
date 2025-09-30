import Foundation
import SwiftData
import Logging

enum ScheduleStorageError: Error {
    case contextNotAvailable
    case scheduleNotFound
    case persistenceError(Error)
    case invalidData
}

struct SyncError: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let errorMessage: String
    let errorCode: String?
    let retryAttempt: Int

    init(errorMessage: String, errorCode: String? = nil, retryAttempt: Int) {
        self.timestamp = Date()
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.retryAttempt = retryAttempt
    }
}

@Model
class ScheduleEntity {
    @Attribute(.unique) var id: String
    var routineId: String // Keep for backward compatibility
    var name: String
    var recurrenceJSON: String
    var dtstart: Date
    @Attribute(.transformable(by: "NSSecureUnarchiveFromDataTransformer")) var exdates: [String]
    var lastExecution: Date?
    var notes: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var syncStatus: SyncStatus
    var lastSyncAttempt: Date?
    var lastModified: Date

    // Error tracking fields (optional for migration compatibility)
    var retryCount: Int?
    var lastError: String?
    @Attribute(.transformable(by: "NSSecureUnarchiveFromDataTransformer")) var syncErrors: [SyncError]?

    // SwiftData relationship to routine
    @Relationship
    var routine: RoutineEntity?

    init(schedule: Schedule, syncStatus: SyncStatus = .localOnly) {
        self.id = schedule.id
        self.routineId = schedule.routineId
        self.name = schedule.name
        self.recurrenceJSON = schedule.recurrenceJSON
        self.dtstart = schedule.dtstart
        self.exdates = schedule.exdates
        self.lastExecution = schedule.lastExecution
        self.notes = schedule.notes
        self.enabled = schedule.enabled
        self.createdAt = schedule.createdAt
        self.updatedAt = schedule.updatedAt
        self.syncStatus = syncStatus
        self.lastModified = Date()

        // Initialize error tracking fields
        self.retryCount = 0
        self.lastError = nil
        self.syncErrors = []
    }

    func toSchedule() -> Schedule {
        return Schedule(
            id: id,
            routineId: routineId,
            name: name,
            recurrenceJSON: recurrenceJSON,
            dtstart: dtstart,
            exdates: exdates,
            lastExecution: lastExecution,
            notes: notes,
            enabled: enabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func updateFromSchedule(_ schedule: Schedule, newSyncStatus: SyncStatus? = nil) {
        self.name = schedule.name
        self.recurrenceJSON = schedule.recurrenceJSON
        self.dtstart = schedule.dtstart
        self.exdates = schedule.exdates
        self.lastExecution = schedule.lastExecution
        self.notes = schedule.notes
        self.enabled = schedule.enabled
        self.updatedAt = schedule.updatedAt
        self.lastModified = Date()

        if let newSyncStatus = newSyncStatus {
            self.syncStatus = newSyncStatus
        }
    }
}

@MainActor
class ScheduleLocalStorage: ObservableObject {
    static let shared = ScheduleLocalStorage()

    private let logger = Logger(label: "com.vibecare.schedule-storage")

    private var context: ModelContext {
        SharedDataStorage.shared.context
    }

    private init() {
        logger.info("ScheduleLocalStorage initialized with shared context")
    }

    // MARK: - CRUD Operations

    func createSchedule(_ schedule: Schedule) throws -> Schedule {
        let entity = ScheduleEntity(schedule: schedule, syncStatus: .localOnly)

        // Link to routine entity if it exists
        if let routineEntity = try findRoutineEntity(id: schedule.routineId) {
            entity.routine = routineEntity
            routineEntity.schedules.append(entity)
            logger.debug("Linked schedule to routine entity: \(schedule.routineId)")
        } else {
            logger.warning("Creating schedule without routine entity link - routine not found: \(schedule.routineId)")
        }

        context.insert(entity)

        do {
            try context.save()
            logger.info("Created schedule locally: \(schedule.name)")
            return entity.toSchedule()
        } catch {
            logger.error("Failed to create schedule: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getSchedule(id: String) throws -> Schedule? {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            return entities.first?.toSchedule()
        } catch {
            logger.error("Failed to get schedule: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func updateSchedule(_ schedule: Schedule) throws -> Schedule {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == schedule.id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            // Mark as pending sync if it was previously synced
            let newSyncStatus: SyncStatus = entity.syncStatus == .synced ? .pendingSync : entity.syncStatus

            entity.updateFromSchedule(schedule, newSyncStatus: newSyncStatus)
            try context.save()

            logger.info("Updated schedule locally: \(schedule.name)")
            return entity.toSchedule()
        } catch {
            logger.error("Failed to update schedule: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func deleteSchedule(id: String) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            // Soft delete: Mark for deletion instead of removing
            entity.syncStatus = .pendingDelete
            entity.lastModified = Date()

            try context.save()

            logger.info("Marked schedule for deletion: \(id)")
        } catch {
            logger.error("Failed to mark schedule for deletion: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // Permanently delete schedule after successful sync
    func permanentlyDeleteSchedule(id: String) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            context.delete(entity)
            try context.save()

            logger.info("Permanently deleted schedule: \(id)")
        } catch {
            logger.error("Failed to permanently delete schedule: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func listSchedules(for routineId: String) throws -> [Schedule] {
        // Fetch all schedules for the routine
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.routineId == routineId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\ScheduleEntity.updatedAt, order: .reverse)]
        )

        do {
            let entities = try context.fetch(descriptor)
            // Filter out schedules marked for deletion
            let activeEntities = entities.filter { $0.syncStatus != .pendingDelete }
            return activeEntities.map { $0.toSchedule() }
        } catch {
            logger.error("Failed to list schedules: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getAllSchedules(for routineId: String) throws -> [Schedule] {
        // Fetch ALL schedules for the routine, including pending deletion
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.routineId == routineId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\ScheduleEntity.updatedAt, order: .reverse)]
        )

        do {
            let entities = try context.fetch(descriptor)
            // Return ALL schedules without filtering
            return entities.map { $0.toSchedule() }
        } catch {
            logger.error("Failed to get all schedules: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getAllSchedulesAcrossAllRoutines() throws -> [Schedule] {
        // Fetch ALL schedules across all routines, including pending deletion
        let descriptor = FetchDescriptor<ScheduleEntity>(
            sortBy: [SortDescriptor(\ScheduleEntity.updatedAt, order: .reverse)]
        )

        do {
            let entities = try context.fetch(descriptor)
            // Return ALL schedules without filtering
            return entities.map { $0.toSchedule() }
        } catch {
            logger.error("Failed to get all schedules across all routines: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // MARK: - Sync Status Management

    func updateSyncStatus(scheduleId: String, status: SyncStatus) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            entity.syncStatus = status
            entity.lastSyncAttempt = Date()

            try context.save()
            logger.info("Updated sync status for schedule \(scheduleId): \(status.rawValue)")
        } catch {
            logger.error("Failed to update sync status: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getSchedulesNeedingSync() throws -> [Schedule] {
        // Fetch all schedules and filter in Swift for now
        let descriptor = FetchDescriptor<ScheduleEntity>()

        do {
            let entities = try context.fetch(descriptor)
            let filteredEntities = entities.filter { entity in
                entity.syncStatus == .localOnly ||
                entity.syncStatus == .pendingSync ||
                entity.syncStatus == .syncFailed
            }
            return filteredEntities.map { $0.toSchedule() }
        } catch {
            logger.error("Failed to get schedules needing sync: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getSchedulesNeedingDeletion() throws -> [Schedule] {
        let descriptor = FetchDescriptor<ScheduleEntity>()

        do {
            let entities = try context.fetch(descriptor)
            let deletionEntities = entities.filter { entity in
                entity.syncStatus == .pendingDelete
            }
            return deletionEntities.map { $0.toSchedule() }
        } catch {
            logger.error("Failed to get schedules needing deletion: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // MARK: - Batch Operations

    func batchUpdateSyncStatus(scheduleIds: [String], status: SyncStatus) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            scheduleIds.contains(entity.id)
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            for entity in entities {
                entity.syncStatus = status
                entity.lastSyncAttempt = Date()
            }

            try context.save()
            logger.info("Batch updated sync status for \(entities.count) schedules to \(status.rawValue)")
        } catch {
            logger.error("Failed to batch update sync status: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // MARK: - Statistics

    func getSyncStatistics() throws -> [SyncStatus: Int] {
        var stats: [SyncStatus: Int] = [:]

        for status in SyncStatus.allCases {
            let predicate = #Predicate<ScheduleEntity> { entity in
                entity.syncStatus == status
            }

            let descriptor = FetchDescriptor(predicate: predicate)

            do {
                let entities = try context.fetch(descriptor)
                stats[status] = entities.count
            } catch {
                logger.error("Failed to get count for sync status \(status): \(error)")
            }
        }

        return stats
    }

    // MARK: - Helper Methods

    func getSyncStatus(for scheduleId: String) -> SyncStatus? {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            return entities.first?.syncStatus
        } catch {
            logger.error("Failed to get sync status: \(error)")
            return nil
        }
    }

    func saveContext() throws {
        try SharedDataStorage.shared.save()
    }

    // MARK: - Data Management

    func clearAllSchedules(for routineId: String) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.routineId == routineId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            for entity in entities {
                context.delete(entity)
            }
            try context.save()
            logger.info("Cleared \(entities.count) schedules for routine: \(routineId)")
        } catch {
            logger.error("Failed to clear schedules: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // MARK: - Error Tracking

    func recordSyncError(scheduleId: String, error: Error, retryAttempt: Int) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            // Increment retry count
            entity.retryCount = (entity.retryCount ?? 0) + 1

            // Record last error
            entity.lastError = error.localizedDescription

            // Create new sync error
            let syncError = SyncError(
                errorMessage: error.localizedDescription,
                errorCode: extractErrorCode(from: error),
                retryAttempt: retryAttempt
            )

            // Add to error history (keep only last 5)
            if entity.syncErrors == nil {
                entity.syncErrors = []
            }
            entity.syncErrors!.append(syncError)
            if entity.syncErrors!.count > 5 {
                entity.syncErrors!.removeFirst()
            }

            // Update last sync attempt
            entity.lastSyncAttempt = Date()

            try context.save()
            logger.info("Recorded sync error for schedule \\(scheduleId): \\(error.localizedDescription)")

        } catch {
            logger.error("Failed to record sync error: \\(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func clearSyncErrors(scheduleId: String) throws {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw ScheduleStorageError.scheduleNotFound
            }

            // Reset error tracking on successful sync
            entity.retryCount = 0
            entity.lastError = nil
            entity.syncErrors = []

            try context.save()
            logger.info("Cleared sync errors for schedule \\(scheduleId)")

        } catch {
            logger.error("Failed to clear sync errors: \\(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    private func extractErrorCode(from error: Error) -> String? {
        // Extract error code from various error types
        if let nsError = error as NSError? {
            return "\\(nsError.domain)-\\(nsError.code)"
        }
        return nil
    }

    func getSyncErrorHistory(for scheduleId: String) throws -> [SyncError] {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                return []
            }
            return entity.syncErrors ?? []
        } catch {
            logger.error("Failed to get sync error history: \\(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getRetryCount(for scheduleId: String) throws -> Int {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.id == scheduleId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                return 0
            }
            return entity.retryCount ?? 0
        } catch {
            logger.error("Failed to get retry count: \\(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    // MARK: - Helper Methods

    private func findRoutineEntity(id: String) throws -> RoutineEntity? {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            return entities.first
        } catch {
            logger.error("Failed to find routine entity: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    #if DEBUG
    // MARK: - Debug Methods

    func getAllScheduleEntities(for routineId: String) throws -> [ScheduleEntity] {
        let predicate = #Predicate<ScheduleEntity> { entity in
            entity.routineId == routineId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch schedule entities: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }

    func getAllScheduleEntities() throws -> [ScheduleEntity] {
        let descriptor = FetchDescriptor<ScheduleEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch all schedule entities: \(error)")
            throw ScheduleStorageError.persistenceError(error)
        }
    }
    #endif
}