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
            // Create app-specific storage location
            let appName = "VibeCare"
            let storeURL: URL

            // Check if running in sandbox/container
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "com.vibecare.VibeCare") {
                // Running in container (production)
                storeURL = containerURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true)
                    .appendingPathComponent("\(appName).sqlite")
                logger.info("Using container storage path")
            } else {
                // Running via swift run or non-sandboxed (development)
                storeURL = URL.applicationSupportDirectory
                    .appendingPathComponent(appName, isDirectory: true)
                    .appendingPathComponent("\(appName).sqlite")
                logger.info("Using application support storage path")
            }

            // Create directory if needed
            let directoryURL = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            // Log the actual path being used
            logger.info("SwiftData store location: \(storeURL.path)")
            logger.info("Store directory exists: \(FileManager.default.fileExists(atPath: directoryURL.path))")

            // Create configuration with specific URL
            let configuration = ModelConfiguration(
                schema: Schema([RoutineEntity.self, ScheduleEntity.self]),
                url: storeURL,
                allowsSave: true
            )

            // Include all entity types in the same container
            self.modelContainer = try ModelContainer(
                for: RoutineEntity.self, ScheduleEntity.self,
                configurations: configuration
            )
            self.context = ModelContext(modelContainer)

            // Log additional debug info
            logStorageInfo(storeURL: storeURL)

            logger.info("Shared SwiftData container initialized successfully at: \(storeURL.path)")
        } catch {
            logger.error("Failed to initialize shared SwiftData container: \(error)")
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    // MARK: - Storage Info

    private func logStorageInfo(storeURL: URL) {
        // Log SQLite files
        let basePath = storeURL.deletingPathExtension().path
        let sqliteFiles = [
            storeURL.path,
            "\(basePath).sqlite-shm",
            "\(basePath).sqlite-wal"
        ]

        logger.info("SQLite database files:")
        for filePath in sqliteFiles {
            if FileManager.default.fileExists(atPath: filePath) {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let size = attributes[.size] as? Int64 {
                    let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                    let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    logger.info("  - \(fileName): \(formattedSize)")
                }
            } else {
                let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                logger.info("  - \(fileName): (not yet created)")
            }
        }
    }

    public func getStoragePath() -> String {
        // Get the current store URL from configuration
        let appName = "VibeCare"
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "com.vibecare.VibeCare") {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("\(appName).sqlite")
                .path
        } else {
            return URL.applicationSupportDirectory
                .appendingPathComponent(appName, isDirectory: true)
                .appendingPathComponent("\(appName).sqlite")
                .path
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