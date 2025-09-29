import Foundation
import SwiftData
import Logging

// Shared ModelContainer for all entities to avoid separate database issues
@MainActor
class SharedDataStorage {
    static let shared = SharedDataStorage()

    private let logger = Logger(label: "com.vibecare.shared-storage")

    let modelContainer: ModelContainer
    let context: ModelContext

    private init() {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
            // Include all entity types in the same container
            self.modelContainer = try ModelContainer(
                for: RoutineEntity.self, ScheduleEntity.self,
                configurations: configuration
            )
            self.context = ModelContext(modelContainer)
            logger.info("Shared SwiftData container initialized successfully")
        } catch {
            logger.error("Failed to initialize shared SwiftData container: \(error)")
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    // MARK: - Database Management

    func save() throws {
        try context.save()
    }

    func rollback() {
        context.rollback()
    }

    // MARK: - Migration Helper

    func resetDatabase() throws {
        logger.warning("Resetting database - all local data will be lost")

        // Delete all entities
        try context.delete(model: RoutineEntity.self)
        try context.delete(model: ScheduleEntity.self)

        try save()
        logger.info("Database reset completed")
    }
}