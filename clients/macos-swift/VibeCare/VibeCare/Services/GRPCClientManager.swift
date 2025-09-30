import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf
import Logging
import VCStubs

@MainActor
class GRPCClientManager: ObservableObject {
    static let shared = GRPCClientManager()

    // MARK: - Published Properties
    @Published var isConnected: Bool = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastError: Error?

    // MARK: - Private Properties
    private let logger = Logger(label: "com.vibecare.grpc-client")

    // Connection settings
    private var host: String {
        UserDefaults.standard.string(forKey: "grpc_host") ?? "localhost"
    }

    private var port: Int {
        UserDefaults.standard.integer(forKey: "grpc_port") != 0
            ? UserDefaults.standard.integer(forKey: "grpc_port")
            : 50051
    }

    private var useTLS: Bool {
        UserDefaults.standard.bool(forKey: "grpc_use_tls")
    }

    private init() {
        logger.info("GRPCClientManager initialized")
    }

    // MARK: - Public Methods

    nonisolated func withProfileServiceClient<T: Sendable>(_ operation: @Sendable (VCProfileService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port)")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            // Configure the gRPC client transport
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            // Use withGRPCClient to manage the client lifecycle
            let result = try await withGRPCClient(transport: transport) { client in
                // Wrap the raw client with the generated, type-safe ProfileService.Client
                let profileServiceClient = VCProfileService.Client(wrapping: client)
                return try await operation(profileServiceClient)
            }

            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .disconnected
            }

            return result

        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .failed
                self.lastError = error
            }
            logger.error("gRPC operation failed: \(error)")
            throw error
        }
    }

    nonisolated func withRoutineServiceClient<T: Sendable>(_ operation: @Sendable (VCRoutineService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for RoutineService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            // Configure the gRPC client transport
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            // Use withGRPCClient to manage the client lifecycle
            let result = try await withGRPCClient(transport: transport) { client in
                // Wrap the raw client with the generated, type-safe RoutineService.Client
                let routineServiceClient = VCRoutineService.Client(wrapping: client)
                return try await operation(routineServiceClient)
            }

            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .disconnected
            }

            return result

        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .failed
                self.lastError = error
            }
            logger.error("gRPC RoutineService operation failed: \(error)")
            throw error
        }
    }

    // MARK: - Schedule Service

    nonisolated func withScheduleServiceClient<T: Sendable>(_ operation: @Sendable (VCScheduleService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for ScheduleService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            // Configure the gRPC client transport
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            // Use withGRPCClient to manage the client lifecycle
            let result = try await withGRPCClient(transport: transport) { client in
                // Wrap the raw client with the generated, type-safe ScheduleService.Client
                let scheduleServiceClient = VCScheduleService.Client(wrapping: client)
                return try await operation(scheduleServiceClient)
            }

            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .disconnected
            }

            return result

        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .failed
                self.lastError = error
            }
            logger.error("gRPC ScheduleService operation failed: \(error)")
            throw error
        }
    }

    // MARK: - Event Service

    nonisolated func withEventServiceClient<T: Sendable>(_ operation: @Sendable (VCEventService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for EventService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            // Configure the gRPC client transport
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            // Use withGRPCClient to manage the client lifecycle
            let result = try await withGRPCClient(transport: transport) { client in
                // Wrap the raw client with the generated, type-safe EventService.Client
                let eventServiceClient = VCEventService.Client(wrapping: client)
                return try await operation(eventServiceClient)
            }

            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .disconnected
            }

            return result

        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionStatus = .failed
                self.lastError = error
            }
            logger.error("gRPC EventService operation failed: \(error)")
            throw error
        }
    }

    // MARK: - Configuration

    func updateConnectionSettings(host: String, port: Int, useTLS: Bool) {
        UserDefaults.standard.set(host, forKey: "grpc_host")
        UserDefaults.standard.set(port, forKey: "grpc_port")
        UserDefaults.standard.set(useTLS, forKey: "grpc_use_tls")

        logger.info("Updated connection settings: \(host):\(port), TLS: \(useTLS)")
    }
}

// MARK: - Supporting Types

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected
    case failed

    var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .failed:
            return "Connection Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected:
            return "circle"
        case .connecting:
            return "arrow.clockwise"
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .disconnected:
            return "secondary"
        case .connecting:
            return "blue"
        case .connected:
            return "green"
        case .failed:
            return "red"
        }
    }
}

enum GRPCClientError: LocalizedError {
    case notConnected
    case clientNotInitialized
    case connectionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .clientNotInitialized:
            return "gRPC client not initialized"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        }
    }
}