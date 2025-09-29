import Foundation
import SwiftData
import Logging

enum SyncStatus: String, CaseIterable, Codable {
    case localOnly = "local_only"
    case synced = "synced"
    case pendingSync = "pending_sync"
    case conflict = "conflict"
    case syncFailed = "sync_failed"
    case pendingDelete = "pending_delete"  // Tombstone for deletion sync
}

enum RoutineStorageError: Error {
    case contextNotAvailable
    case routineNotFound
    case persistenceError(Error)
    case invalidData
}

@Model
class RoutineEntity {
    @Attribute(.unique) var id: String
    var profileId: String
    var name: String
    var routineDescription: String
    @Attribute(.transformable(by: "NSSecureUnarchiveFromDataTransformer")) var actionIds: [String]
    var enabled: Bool
    @Attribute(.transformable(by: "NSSecureUnarchiveFromDataTransformer")) var metadata: [String: String]
    var createdAt: Date
    var updatedAt: Date
    var lastExecutedAt: Date?
    var syncStatus: SyncStatus
    var lastSyncAttempt: Date?
    var lastModified: Date

    init(routine: Routine, syncStatus: SyncStatus = .localOnly) {
        self.id = routine.id
        self.profileId = routine.profileId
        self.name = routine.name
        self.routineDescription = routine.description
        self.actionIds = routine.actionIds
        self.enabled = routine.enabled
        self.metadata = routine.metadata
        self.createdAt = routine.createdAt
        self.updatedAt = routine.updatedAt
        self.lastExecutedAt = routine.lastExecutedAt
        self.syncStatus = syncStatus
        self.lastModified = Date()
    }

    func toRoutine() -> Routine {
        return Routine(
            id: id,
            profileId: profileId,
            name: name,
            description: routineDescription,
            actionIds: actionIds,
            enabled: enabled,
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastExecutedAt: lastExecutedAt
        )
    }

    func updateFromRoutine(_ routine: Routine, newSyncStatus: SyncStatus? = nil) {
        self.name = routine.name
        self.routineDescription = routine.description
        self.actionIds = routine.actionIds
        self.enabled = routine.enabled
        self.metadata = routine.metadata
        self.updatedAt = routine.updatedAt
        self.lastExecutedAt = routine.lastExecutedAt
        self.lastModified = Date()

        if let newSyncStatus = newSyncStatus {
            self.syncStatus = newSyncStatus
        }
    }
}

@MainActor
class RoutineLocalStorage: ObservableObject {
    static let shared = RoutineLocalStorage()

    private let logger = Logger(label: "com.vibecare.routine-storage")

    private var context: ModelContext {
        SharedDataStorage.shared.context
    }

    private init() {
        logger.info("RoutineLocalStorage initialized with shared context")
    }

    // MARK: - CRUD Operations

    func createRoutine(_ routine: Routine) throws -> Routine {
        let entity = RoutineEntity(routine: routine, syncStatus: .localOnly)
        context.insert(entity)

        do {
            try context.save()
            logger.info("Created routine locally: \(routine.name)")
            return entity.toRoutine()
        } catch {
            logger.error("Failed to create routine: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func getRoutine(id: String) throws -> Routine? {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            return entities.first?.toRoutine()
        } catch {
            logger.error("Failed to get routine: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func updateRoutine(_ routine: Routine) throws -> Routine {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == routine.id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw RoutineStorageError.routineNotFound
            }

            // Mark as pending sync if it was previously synced
            let newSyncStatus: SyncStatus = entity.syncStatus == .synced ? .pendingSync : entity.syncStatus

            entity.updateFromRoutine(routine, newSyncStatus: newSyncStatus)
            try context.save()

            logger.info("Updated routine locally: \(routine.name)")
            return entity.toRoutine()
        } catch {
            logger.error("Failed to update routine: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func deleteRoutine(id: String) throws {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw RoutineStorageError.routineNotFound
            }

            // Soft delete: Mark for deletion instead of removing
            entity.syncStatus = .pendingDelete
            entity.lastModified = Date()

            try context.save()

            logger.info("Marked routine for deletion: \(id)")
        } catch {
            logger.error("Failed to mark routine for deletion: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    // Permanently delete routine after successful sync
    func permanentlyDeleteRoutine(id: String) throws {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == id
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw RoutineStorageError.routineNotFound
            }

            context.delete(entity)
            try context.save()

            logger.info("Permanently deleted routine: \(id)")
        } catch {
            logger.error("Failed to permanently delete routine: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func listRoutines(for profileId: String) throws -> [Routine] {
        // Fetch all routines for the profile
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.profileId == profileId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\RoutineEntity.updatedAt, order: .reverse)]
        )

        do {
            let entities = try context.fetch(descriptor)
            // Filter out routines marked for deletion
            let activeEntities = entities.filter { $0.syncStatus != .pendingDelete }
            return activeEntities.map { $0.toRoutine() }
        } catch {
            logger.error("Failed to list routines: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func getAllRoutines(for profileId: String) throws -> [Routine] {
        // Fetch ALL routines for the profile, including pending deletion
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.profileId == profileId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\RoutineEntity.updatedAt, order: .reverse)]
        )

        do {
            let entities = try context.fetch(descriptor)
            // Return ALL routines without filtering
            return entities.map { $0.toRoutine() }
        } catch {
            logger.error("Failed to get all routines: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    // MARK: - Sync Status Management

    func updateSyncStatus(routineId: String, status: SyncStatus) throws {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == routineId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            guard let entity = entities.first else {
                throw RoutineStorageError.routineNotFound
            }

            entity.syncStatus = status
            entity.lastSyncAttempt = Date()

            try context.save()
            logger.info("Updated sync status for routine \(routineId): \(status.rawValue)")
        } catch {
            logger.error("Failed to update sync status: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func getRoutinesNeedingSync() throws -> [Routine] {
        // Fetch all routines and filter in Swift for now
        // SwiftData predicate with enum comparison can be tricky
        let descriptor = FetchDescriptor<RoutineEntity>()

        do {
            let entities = try context.fetch(descriptor)
            let filteredEntities = entities.filter { entity in
                entity.syncStatus == .localOnly ||
                entity.syncStatus == .pendingSync ||
                entity.syncStatus == .syncFailed
            }
            return filteredEntities.map { $0.toRoutine() }
        } catch {
            logger.error("Failed to get routines needing sync: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func getRoutinesNeedingDeletion() throws -> [Routine] {
        let descriptor = FetchDescriptor<RoutineEntity>()

        do {
            let entities = try context.fetch(descriptor)
            let deletionEntities = entities.filter { entity in
                entity.syncStatus == .pendingDelete
            }
            return deletionEntities.map { $0.toRoutine() }
        } catch {
            logger.error("Failed to get routines needing deletion: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    // MARK: - Batch Operations

    func batchUpdateSyncStatus(routineIds: [String], status: SyncStatus) throws {
        let predicate = #Predicate<RoutineEntity> { entity in
            routineIds.contains(entity.id)
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            for entity in entities {
                entity.syncStatus = status
                entity.lastSyncAttempt = Date()
            }

            try context.save()
            logger.info("Batch updated sync status for \(entities.count) routines to \(status.rawValue)")
        } catch {
            logger.error("Failed to batch update sync status: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    // MARK: - Statistics

    func getSyncStatistics() throws -> [SyncStatus: Int] {
        var stats: [SyncStatus: Int] = [:]

        for status in SyncStatus.allCases {
            let predicate = #Predicate<RoutineEntity> { entity in
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

    func getSyncStatus(for routineId: String) -> SyncStatus? {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.id == routineId
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

    func clearAllRoutines(for profileId: String) throws {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.profileId == profileId
        }

        let descriptor = FetchDescriptor(predicate: predicate)

        do {
            let entities = try context.fetch(descriptor)
            for entity in entities {
                context.delete(entity)
            }
            try context.save()
            logger.info("Cleared \(entities.count) routines for profile: \(profileId)")
        } catch {
            logger.error("Failed to clear routines: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    #if DEBUG
    // MARK: - Debug Methods

    func getAllRoutineEntities(for profileId: String) throws -> [RoutineEntity] {
        let predicate = #Predicate<RoutineEntity> { entity in
            entity.profileId == profileId
        }

        let descriptor = FetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch routine entities: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }

    func getAllRoutineEntities() throws -> [RoutineEntity] {
        let descriptor = FetchDescriptor<RoutineEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch all routine entities: \(error)")
            throw RoutineStorageError.persistenceError(error)
        }
    }
    #endif
}