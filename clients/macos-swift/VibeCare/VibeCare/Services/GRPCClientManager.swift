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

    // Connection settings - reads from grpc_url or falls back to legacy keys
    private var host: String {
        // Try new URL-based config first
        if let grpcURL = UserDefaults.standard.string(forKey: "grpc_url"),
           let components = NetworkConfiguration.parseGRPCURL(grpcURL) {
            return components.host
        }
        // Fallback to legacy host key
        return UserDefaults.standard.string(forKey: "grpc_host") ?? "localhost"
    }

    private var port: Int {
        // Try new URL-based config first
        if let grpcURL = UserDefaults.standard.string(forKey: "grpc_url"),
           let components = NetworkConfiguration.parseGRPCURL(grpcURL) {
            return components.port
        }
        // Fallback to legacy port key
        return UserDefaults.standard.integer(forKey: "grpc_port") != 0
            ? UserDefaults.standard.integer(forKey: "grpc_port")
            : 50051
    }

    private var useTLS: Bool {
        // Try new URL-based config first
        if let grpcURL = UserDefaults.standard.string(forKey: "grpc_url"),
           let components = NetworkConfiguration.parseGRPCURL(grpcURL) {
            return components.useTLS
        }
        // Fallback to legacy TLS key
        return UserDefaults.standard.bool(forKey: "grpc_use_tls")
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

    nonisolated func withActionServiceClient<T: Sendable>(_ operation: @Sendable (VCActionService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for ActionService")

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
                // Wrap the raw client with the generated, type-safe ActionService.Client
                let actionServiceClient = VCActionService.Client(wrapping: client)
                return try await operation(actionServiceClient)
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
            logger.error("gRPC ActionService operation failed: \(error)")
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

    func updateConnectionSettings(host: String, port: Int, webPort: Int, useTLS: Bool) {
        UserDefaults.standard.set(host, forKey: "grpc_host")
        UserDefaults.standard.set(port, forKey: "grpc_port")
        UserDefaults.standard.set(webPort, forKey: "web_port")
        UserDefaults.standard.set(useTLS, forKey: "grpc_use_tls")

        logger.info("Updated connection settings - gRPC: \(host):\(port), Web: \(webPort), TLS: \(useTLS)")
    }

    // MARK: - Template Service Client

    nonisolated func getTemplateServiceClient() -> VCScheduleTemplateService.Client<HTTP2ClientTransport.Posix> {
        fatalError("Use withTemplateServiceClient instead - this is a placeholder for synchronous access")
    }

    nonisolated func withTemplateServiceClient<T: Sendable>(_ operation: @Sendable (VCScheduleTemplateService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for ScheduleTemplateService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            let result = try await withGRPCClient(transport: transport) { client in
                let templateServiceClient = VCScheduleTemplateService.Client(wrapping: client)
                return try await operation(templateServiceClient)
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

    // MARK: - Plugin Host Service Client

    nonisolated func withPluginHostServiceClient<T: Sendable>(_ operation: @Sendable (VCPluginHostService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for PluginHostService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            let result = try await withGRPCClient(transport: transport) { client in
                let pluginHostServiceClient = VCPluginHostService.Client(wrapping: client)
                return try await operation(pluginHostServiceClient)
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
            logger.error("gRPC PluginHostService operation failed: \(error)")
            throw error
        }
    }

    // MARK: - Plugin Shell Client (v2 kernel)

    /// The client's entire plugin surface: two frozen RPCs (`Plugins`,
    /// `Intents`). Deliberately does NOT touch `connectionStatus` — the two
    /// shell streams are long-lived, and flipping the shared status to
    /// `.disconnected` when either ends would misreport the app's overall
    /// connection state.
    nonisolated func withShellClient<T: Sendable>(_ operation: @Sendable (VCKShell.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for Shell")

        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )
            return try await withGRPCClient(transport: transport) { client in
                try await operation(VCKShell.Client(wrapping: client))
            }
        } catch {
            logger.error("gRPC Shell operation failed: \(error)")
            throw error
        }
    }

    // MARK: - Icon Service Client

    nonisolated func withIconServiceClient<T: Sendable>(_ operation: @Sendable (VCIconService.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for IconService")

        await MainActor.run {
            self.connectionStatus = .connecting
        }

        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )

            await MainActor.run {
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }

            let result = try await withGRPCClient(transport: transport) { client in
                let iconServiceClient = VCIconService.Client(wrapping: client)
                return try await operation(iconServiceClient)
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
            logger.error("gRPC IconService operation failed: \(error)")
            throw error
        }
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