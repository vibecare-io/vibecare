import Foundation
import GRPC
import NIOCore
import NIOPosix
import Logging

@MainActor
class GRPCClient: ObservableObject {
    static let shared = GRPCClient()

    @Published var isConnected: Bool = false

    private var eventLoopGroup: EventLoopGroup?
    private var channel: GRPCChannel?
    private let logger = Logger(label: "com.vibecare.grpc")

    // Configuration
    private let host: String
    private let port: Int
    private let maxRetries: Int = 3
    private let retryDelay: TimeInterval = 2.0

    private init() {
        self.host = UserDefaults.standard.string(forKey: "grpc_host") ?? "localhost"
        self.port = UserDefaults.standard.integer(forKey: "grpc_port") != 0
            ? UserDefaults.standard.integer(forKey: "grpc_port")
            : 50051
    }

    // MARK: - Connection Management

    func connect() {
        Task {
            await performConnection()
        }
    }

    func reconnect() async {
        await disconnect()
        await performConnection()
    }

    func disconnect() async {
        do {
            try await channel?.close().get()
            try await eventLoopGroup?.shutdownGracefully()
        } catch {
            logger.error("Error during disconnect: \(error)")
        }

        await MainActor.run {
            self.channel = nil
            self.eventLoopGroup = nil
            self.isConnected = false
        }

        logger.info("Disconnected from gRPC server")
    }

    private func performConnection() async {
        logger.info("Attempting to connect to \(host):\(port)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        do {
            let channel = try GRPCChannelPool.with(
                target: .host(host, port: port),
                transportSecurity: .plaintext,
                eventLoopGroup: group
            )

            // Test connection with a health check
            try await testConnection(channel: channel)

            await MainActor.run {
                self.channel = channel
                self.isConnected = true
            }

            logger.info("Successfully connected to gRPC server")

        } catch {
            logger.error("Failed to connect to gRPC server: \(error)")

            await MainActor.run {
                self.isConnected = false
            }

            // Cleanup on failure
            try? await group.shutdownGracefully()
        }
    }

    private func testConnection(channel: GRPCChannel) async throws {
        // We'll implement a simple health check once we have the profile service
        // For now, just verify the channel is created
        logger.debug("Connection test completed")
    }

    // MARK: - Channel Access

    func getChannel() throws -> GRPCChannel {
        guard let channel = channel, isConnected else {
            throw GRPCClientError.notConnected
        }
        return channel
    }

    // MARK: - Configuration

    func updateConnectionSettings(host: String, port: Int) {
        UserDefaults.standard.set(host, forKey: "grpc_host")
        UserDefaults.standard.set(port, forKey: "grpc_port")

        Task {
            await reconnect()
        }
    }
}

// MARK: - Errors

enum GRPCClientError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to VibeCare backend"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .serviceUnavailable:
            return "VibeCare service is currently unavailable"
        }
    }
}