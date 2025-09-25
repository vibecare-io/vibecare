import Foundation
import Logging

@available(macOS 15.0, *)
class TestRunner {
    private let logger = Logger(label: "test-runner")

    func runGRPCTests() async {
        logger.info("🚀 Starting VibeCare gRPC Test Suite")

        let grpcTest = GRPCTest()
        await grpcTest.runAllTests()

        logger.info("🎯 Test suite completed")
    }

    func runSingleTest(_ testType: TestType) async {
        logger.info("🔬 Running single test: \(testType)")

        let grpcTest = GRPCTest()

        do {
            switch testType {
            case .properClientConfiguration:
                try await grpcTest.testWithProperClientConfiguration()
            case .manualClientCreation:
                try await grpcTest.testWithManualClientCreation()
            case .withInterceptors:
                try await grpcTest.testWithInterceptors()
            }
            logger.info("✅ Single test PASSED: \(testType)")
        } catch {
            logger.error("❌ Single test FAILED: \(testType) - \(error)")
        }
    }
}

enum TestType: String, CaseIterable {
    case properClientConfiguration = "Proper Client Configuration"
    case manualClientCreation = "Manual Client Creation"
    case withInterceptors = "With Interceptors"
}