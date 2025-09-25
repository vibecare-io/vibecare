import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Logging

@available(macOS 15.0, *)
public final class GRPCTest: @unchecked Sendable {
    private let logger = Logger(label: "grpc-test")

    public init() {}

    // Test with the recommended pattern from the blog post
    public func testWithProperClientConfiguration() async throws {
        logger.info("Starting gRPC test with proper client configuration")

        // Create transport with proper configuration
        let transport = try HTTP2ClientTransport.Posix(
          target: .dns(host: "127.0.0.1", port: 50051),
            transportSecurity: .plaintext,
            config: .defaults
        )

        // Create client with proper lifecycle management
        let client = GRPCClient(transport: transport)

        do {
            logger.info("gRPC client created successfully")

            // Create the ProfileService client
            let profileClient = VCProfileService.Client(wrapping: client)
            logger.info("ProfileService client created")

            // Create request
            let request = VCListProfilesRequest()
            logger.info("Request created: \(request)")

            // Make the call with timeout
            logger.info("Making listProfiles call...")

            let response = try await withTimeout(seconds: 5) {
                try await profileClient.listProfiles(request)
            }

            logger.info("SUCCESS: Received \(response.profiles.count) profiles")

            for profile in response.profiles {
                logger.info("Profile: \(profile.name) (\(profile.email))")
            }

        } catch {
            logger.error("FAILED: gRPC call failed with error: \(error)")
            throw error
        }

        // Clean shutdown
        client.beginGracefulShutdown()
    }

    // Test with manual client creation (our current approach)
    public func testWithManualClientCreation() async throws {
        logger.info("Starting gRPC test with manual client creation")

        // Create transport manually
        let transport = try HTTP2ClientTransport.Posix(
          target: .dns(host: "127.0.0.1", port: 50051),
            transportSecurity: .plaintext,
            config: .defaults
        )

        // Create client
        let client = GRPCClient(transport: transport)
        defer {
            client.beginGracefulShutdown()
        }

        // Create service client
        let profileClient = VCProfileService.Client(wrapping: client)

        // Create request
        let request = VCListProfilesRequest()

        // Make the call
        logger.info("Making listProfiles call with manual client...")

        let response = try await withTimeout(seconds: 5) {
            try await profileClient.listProfiles(request)
        }

        logger.info("SUCCESS: Received \(response.profiles.count) profiles with manual client")
    }

    // Test with interceptors for debugging
    public func testWithInterceptors() async throws {
        logger.info("Starting gRPC test with interceptors")

        // Create transport with debugging configuration
        var config = HTTP2ClientTransport.Posix.Config.defaults
        config.compression.enabledAlgorithms = []  // Disable compression for debugging

        let transport = try HTTP2ClientTransport.Posix(
          target: .dns(host: "127.0.0.1", port: 50051),
            transportSecurity: .plaintext,
            config: config
        )

        let client = GRPCClient(transport: transport)

        do {
            // Create service client
            let profileClient = VCProfileService.Client(wrapping: client)

            // Create request with metadata
            let request = VCListProfilesRequest()
            let metadata: GRPCCore.Metadata = [
                "client-version": "1.0.0",
                "user-agent": "vibecare-swift"
            ]

            logger.info("Making call with interceptors and metadata...")

            let response = try await withTimeout(seconds: 5) {
                try await profileClient.listProfiles(
                    request,
                    metadata: metadata,
                    options: .defaults
                )
            }

            logger.info("SUCCESS: Interceptor test completed with \(response.profiles.count) profiles")

        } catch {
            logger.error("FAILED: Interceptor test failed with error: \(error)")
            throw error
        }

        client.beginGracefulShutdown()
    }

    // Helper function for timeout
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw GRPCTestError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // Run all tests
    public func runAllTests() async {
        logger.info("🧪 Starting comprehensive gRPC tests")

        let tests: [(String, () async throws -> Void)] = [
            ("Proper Client Configuration", testWithProperClientConfiguration),
            ("Manual Client Creation", testWithManualClientCreation),
            ("With Interceptors", testWithInterceptors)
        ]

        for (testName, test) in tests {
            logger.info("📝 Running test: \(testName)")

            do {
                try await test()
                logger.info("✅ Test PASSED: \(testName)")
            } catch {
                logger.error("❌ Test FAILED: \(testName) - \(error)")
            }

            // Wait between tests
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        logger.info("🏁 All tests completed")
    }
}

enum GRPCTestError: Error {
    case timeout
}

