import Foundation
import Logging
import VibeCareCore

// Test runner for our fixed ProfileService
@available(macOS 15.0, *)
@main
struct TestGRPCMain {
    static func main() async {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "test-main")

        logger.info("🚀 Testing Fixed VibeCare ProfileService")
        logger.info("========================================")

        let profileService = ProfileService()

        logger.info("")
        logger.info("📋 Testing ProfileService with fixed gRPC-Swift-2...")
        logger.info("")

        do {
            logger.info("🔍 Testing listProfiles...")
            let profiles = try await profileService.listProfiles()
            logger.info("✅ SUCCESS! ProfileService.listProfiles() returned \(profiles.count) profiles")

            for profile in profiles {
                logger.info("   📝 Profile: \(profile.name) (\(profile.email))")
            }

        } catch {
            logger.error("❌ ProfileService test failed: \(error)")
        }

        logger.info("")
        logger.info("========================================")
        logger.info("🏁 ProfileService test completed")

        // Keep the process alive briefly to see all logs
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}