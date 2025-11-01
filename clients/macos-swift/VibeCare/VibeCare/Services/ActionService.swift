import Foundation
import Logging
import VCStubs

class ActionService: @unchecked Sendable {
    private let logger = Logger(label: "com.vibecare.action-service")

    init() {
        logger.info("ActionService initialized")
    }

    // MARK: - Action CRUD Operations

    nonisolated func createAction(_ action: Action) async throws -> Action {
        logger.info("Creating action: \(action.name) with ID: \(action.id), enabled: \(action.enabled)")

        let request = VCCreateActionRequest.with { req in
            req.id = action.id  // Client-provided UUID
            req.profileID = action.profileId
            req.type = convertToVCActionType(action.type)
            req.name = action.name
            req.description_p = action.description
            req.parameters = action.parameters
            req.enabled = action.enabled
        }

        let response = try await GRPCClientManager.shared.withActionServiceClient { client in
            return try await client.createAction(request)
        }

        logger.info("Action created successfully: \(response.name), enabled: \(response.enabled)")

        // Verify ID matches
        if response.id != action.id {
            logger.warning("Server returned different ID! Client: \(action.id), Server: \(response.id)")
        } else {
            logger.info("Server accepted client ID: \(action.id)")
        }

        return try convertToAction(response)
    }

    nonisolated func getAction(id: String) async throws -> Action? {
        logger.info("Fetching action: \(id)")

        let request = VCGetActionRequest.with { req in
            req.id = id
        }

        let response = try await GRPCClientManager.shared.withActionServiceClient { client in
            return try await client.getAction(request)
        }

        logger.info("Action fetched successfully: \(response.name)")

        return try convertToAction(response)
    }

    nonisolated func updateAction(_ action: Action) async throws -> Action {
        logger.info("Updating action: \(action.name), enabled: \(action.enabled)")

        let request = VCUpdateActionRequest.with { req in
            req.id = action.id
            req.name = action.name
            req.description_p = action.description
            req.parameters = action.parameters
            req.enabled = action.enabled
        }

        let response = try await GRPCClientManager.shared.withActionServiceClient { client in
            return try await client.updateAction(request)
        }

        logger.info("Action updated successfully: \(response.name), enabled: \(response.enabled)")

        return try convertToAction(response)
    }

    nonisolated func deleteAction(id: String) async throws {
        logger.info("Deleting action: \(id)")

        let request = VCDeleteActionRequest.with { req in
            req.id = id
        }

        _ = try await GRPCClientManager.shared.withActionServiceClient { client in
            return try await client.deleteAction(request)
        }

        logger.info("Action deleted successfully: \(id)")
    }

    nonisolated func listActions(for profileId: String) async throws -> [Action] {
        logger.info("Listing actions for profile: \(profileId)")

        let request = VCListActionsRequest.with { req in
            req.profileID = profileId
            req.pageSize = 100 // Reasonable default
        }

        let response = try await GRPCClientManager.shared.withActionServiceClient { client in
            return try await client.listActions(request)
        }

        logger.info("Listed \(response.actions.count) actions for profile: \(profileId)")

        return try response.actions.map { try convertToAction($0) }
    }

    // MARK: - Helper Methods

    private nonisolated func convertToAction(_ vcAction: VCAction) throws -> Action {
        let actionType = convertFromVCActionType(vcAction.type)

        return Action(
            id: vcAction.id,
            profileId: vcAction.profileID,
            type: actionType,
            name: vcAction.name,
            description: vcAction.description_p,
            parameters: vcAction.parameters,
            createdAt: vcAction.createdAt.date,
            enabled: vcAction.enabled
        )
    }

    private nonisolated func convertToVCActionType(_ type: ActionType) -> VCActionType {
        switch type {
        case .notification: return .notification
        case .openLink: return .openLink
        case .sendEmail: return .sendEmail
        case .runScript: return .runScript
        case .playSound: return .playSound
        case .systemCommand: return .systemCommand
        case .apiCall: return .apiCall
        case .logEntry: return .logEntry
        }
    }

    private nonisolated func convertFromVCActionType(_ type: VCActionType) -> ActionType {
        switch type {
        case .notification: return .notification
        case .openLink: return .openLink
        case .sendEmail: return .sendEmail
        case .runScript: return .runScript
        case .playSound: return .playSound
        case .systemCommand: return .systemCommand
        case .apiCall: return .apiCall
        case .logEntry: return .logEntry
        case .unspecified, .UNRECOGNIZED: return .notification  // Default fallback
        }
    }
}

enum ActionServiceError: LocalizedError {
    case invalidActionType(String)

    var errorDescription: String? {
        switch self {
        case .invalidActionType(let type):
            return "Invalid action type: \(type)"
        }
    }
}
