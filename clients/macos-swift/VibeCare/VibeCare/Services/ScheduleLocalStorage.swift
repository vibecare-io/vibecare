import Foundation
import SwiftData
import Logging

enum ScheduleStorageError: Error {
    case contextNotAvailable
    case scheduleNotFound
    case persistenceError(Error)
    case invalidData
}

@Model
class ScheduleEntity {
    @Attribute(.unique) var id: String
    var routineId: String
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