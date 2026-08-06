import Foundation
import Logging
import SwiftProtobuf
import VCStubs

/// Local representation of `VCPluginSummary`, mirroring the proto shape.
struct PluginSummary: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let uiKind: String
    let uiEntry: String
    /// "ready" | "unavailable"
    let status: String
}

/// Thin wrapper over `PluginHostService`. The client talks ONLY to Core via
/// this service - never directly to plugins.
class PluginService: ObservableObject, @unchecked Sendable {
    private let logger = Logger(label: "com.vibecare.plugin-service")

    init() {
        logger.info("PluginService initialized")
    }

    // MARK: - Plugin Operations

    /// Lists plugins known to Core. On connection failure, returns an empty
    /// array (consistent with the rest of the client's "no offline logic"
    /// convention - see `ActionService`).
    nonisolated func listPlugins() async -> [PluginSummary] {
        logger.info("Listing plugins")

        do {
            let response = try await GRPCClientManager.shared.withPluginHostServiceClient { client in
                return try await client.listPlugins(SwiftProtobuf.Google_Protobuf_Empty())
            }

            logger.info("Listed \(response.plugins.count) plugins")

            return response.plugins.map { convertToPluginSummary($0) }
        } catch {
            logger.error("Failed to list plugins: \(error)")
            return []
        }
    }

    nonisolated func renderView(pluginId: String, viewId: String) async throws -> Vibecare_Plugin_V1_ViewDescriptor {
        logger.info("Rendering plugin view: \(pluginId)/\(viewId)")

        let request = VCRenderPluginViewRequest.with { req in
            req.pluginID = pluginId
            req.viewID = viewId
        }

        let response = try await GRPCClientManager.shared.withPluginHostServiceClient { client in
            return try await client.renderPluginView(request)
        }

        logger.info("Rendered plugin view: \(pluginId)/\(viewId)")

        return response
    }

    nonisolated func invoke(pluginId: String, viewId: String, action: String, params: [String: String]) async throws -> Vibecare_Plugin_V1_ViewDescriptor {
        logger.info("Invoking plugin action: \(pluginId)/\(viewId)/\(action)")

        let request = VCInvokePluginActionRequest.with { req in
            req.pluginID = pluginId
            req.viewID = viewId
            req.action = action
            req.params = params
        }

        let response = try await GRPCClientManager.shared.withPluginHostServiceClient { client in
            return try await client.invokePluginAction(request)
        }

        logger.info("Invoked plugin action: \(pluginId)/\(viewId)/\(action)")

        return response
    }

    // MARK: - Helper Methods

    private nonisolated func convertToPluginSummary(_ vcPlugin: VCPluginSummary) -> PluginSummary {
        return PluginSummary(
            id: vcPlugin.id,
            name: vcPlugin.name,
            icon: vcPlugin.icon,
            uiKind: vcPlugin.uiKind,
            uiEntry: vcPlugin.uiEntry,
            status: vcPlugin.status
        )
    }
}
