import Foundation
import Logging
import SwiftProtobuf
import GRPCCore
import GRPCProtobuf
import VCStubs

enum RoutineServiceError: Error {
    case timeout
    case routineNotFound
    case invalidRequest
    case serverError(String)
}

final class RoutineService: @unchecked Sendable {

    init() {}
    private let logger = Logger(label: "com.vibecare.routine-service")

    // MARK: - Routine CRUD Operations

    func createRoutine(
        id: String,
        profileId: String,
        name: String,
        description: String,
        actionIds: [String],
        enabled: Bool = true,
        metadata: [String: String] = [:]
    ) async throws -> Routine {
        logger.info("Creating routine: \(name) for profile: \(profileId)")

        do {
            let routine = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCCreateRoutineRequest()
                request.id = id  // Client-provided ID for local-first architecture
                request.profileID = profileId
                request.name = name
                request.description_p = description
                request.actionIds = actionIds
                request.enabled = enabled
                request.metadata = metadata

                logger.info("Making gRPC call to createRoutine...")

                let clientRequest = ClientRequest(message: request)
                let response = try await client.createRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCCreateRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCCreateRoutineResponse>()
                )

                logger.info("Received response from server")

                let routine = convertToRoutine(response.routine)
                logger.info("Successfully created routine: \(routine.id)")
                return routine
            }

            return routine

        } catch {
            logger.error("Failed to create routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func getRoutine(id: String) async throws -> Routine? {
        logger.info("Getting routine: \(id)")

        do {
            let routine = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCGetRoutineRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                let response = try await client.getRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCGetRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCGetRoutineResponse>()
                )

                let routine = convertToRoutine(response.routine)
                logger.info("Successfully retrieved routine: \(routine.id)")
                return routine
            }

            return routine

        } catch {
            logger.error("Failed to get routine: \(error)")
            // Don't throw for not found, return nil instead
            let errorDescription = error.localizedDescription.lowercased()
            if errorDescription.contains("not found") || errorDescription.contains("notfound") {
                return nil
            }
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func updateRoutine(_ routine: Routine) async throws -> Routine {
        logger.info("Updating routine: \(routine.id)")

        do {
            let updatedRoutine = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCUpdateRoutineRequest()
                request.id = routine.id
                request.name = routine.name
                request.description_p = routine.description
                request.actionIds = routine.actionIds
                request.metadata = routine.metadata

                let clientRequest = ClientRequest(message: request)
                let updatedVCRoutine = try await client.updateRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCUpdateRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCRoutine>()
                )

                let updatedRoutine = convertToRoutine(updatedVCRoutine)
                logger.info("Routine updated successfully")
                return updatedRoutine
            }

            return updatedRoutine

        } catch {
            logger.error("Failed to update routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func deleteRoutine(id: String) async throws {
        logger.info("Deleting routine: \(id)")

        do {
            try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCDeleteRoutineRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                _ = try await client.deleteRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCDeleteRoutineRequest>(),
                    deserializer: ProtobufDeserializer<SwiftProtobuf.Google_Protobuf_Empty>()
                )

                logger.info("Routine deleted successfully")
            }

        } catch {
            logger.error("Failed to delete routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func listRoutines(for profileId: String, enabledOnly: Bool = false) async throws -> [Routine] {
        logger.info("Listing routines for profile: \(profileId)")

        do {
            let routines = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCListRoutinesRequest()
                request.profileID = profileId
                request.enabledOnly = enabledOnly

                logger.info("Making gRPC call to listRoutines...")

                let clientRequest = ClientRequest(message: request)
                let response = try await client.listRoutines(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCListRoutinesRequest>(),
                    deserializer: ProtobufDeserializer<VCListRoutinesResponse>()
                )

                logger.info("Received response from server")

                let routines = response.routines.map { vcRoutine in
                    convertToRoutine(vcRoutine)
                }

                logger.info("Successfully fetched \(routines.count) routines from server")
                return routines
            }

            return routines

        } catch {
            logger.error("Failed to list routines: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    // MARK: - Routine Control Operations

    func enableRoutine(id: String) async throws -> Routine {
        logger.info("Enabling routine: \(id)")

        do {
            let routine = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCEnableRoutineRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                let vcRoutine = try await client.enableRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCEnableRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCRoutine>()
                )

                let routine = convertToRoutine(vcRoutine)
                logger.info("Routine enabled successfully")
                return routine
            }

            return routine

        } catch {
            logger.error("Failed to enable routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func disableRoutine(id: String) async throws -> Routine {
        logger.info("Disabling routine: \(id)")

        do {
            let routine = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCDisableRoutineRequest()
                request.id = id

                let clientRequest = ClientRequest(message: request)
                let vcRoutine = try await client.disableRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCDisableRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCRoutine>()
                )

                let routine = convertToRoutine(vcRoutine)
                logger.info("Routine disabled successfully")
                return routine
            }

            return routine

        } catch {
            logger.error("Failed to disable routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    func executeRoutine(id: String, force: Bool = false, notes: String = "") async throws -> ExecutionLog {
        logger.info("Executing routine: \(id)")

        do {
            let executionLog = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCExecuteRoutineRequest()
                request.routineID = id
                request.force = force
                request.notes = notes

                let clientRequest = ClientRequest(message: request)
                let vcExecutionLog = try await client.executeRoutine(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCExecuteRoutineRequest>(),
                    deserializer: ProtobufDeserializer<VCExecutionLog>()
                )

                let executionLog = convertToExecutionLog(vcExecutionLog)
                logger.info("Routine executed successfully")
                return executionLog
            }

            return executionLog

        } catch {
            logger.error("Failed to execute routine: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    // MARK: - Execution History

    func getExecutionLogs(
        for routineId: String,
        startTime: Date? = nil,
        endTime: Date? = nil,
        limit: Int = 50
    ) async throws -> [ExecutionLog] {
        logger.info("Getting execution logs for routine: \(routineId)")

        do {
            let logs = try await GRPCClientManager.shared.withRoutineServiceClient { client in
                var request = VCGetExecutionLogsRequest()
                request.routineID = routineId
                if let startTime = startTime {
                    request.startTime = Google_Protobuf_Timestamp(date: startTime)
                }
                if let endTime = endTime {
                    request.endTime = Google_Protobuf_Timestamp(date: endTime)
                }
                request.limit = Int32(limit)

                let clientRequest = ClientRequest(message: request)
                let response = try await client.getExecutionLogs(
                    request: clientRequest,
                    serializer: ProtobufSerializer<VCGetExecutionLogsRequest>(),
                    deserializer: ProtobufDeserializer<VCGetExecutionLogsResponse>()
                )

                let logs = response.logs.map { vcLog in
                    convertToExecutionLog(vcLog)
                }

                logger.info("Successfully fetched \(logs.count) execution logs")
                return logs
            }

            return logs

        } catch {
            logger.error("Failed to get execution logs: \(error)")
            throw RoutineServiceError.serverError(error.localizedDescription)
        }
    }

    // MARK: - Private Helper Methods

    private func convertToRoutine(_ vcRoutine: VCRoutine) -> Routine {
        return Routine(
            id: vcRoutine.id,
            profileId: vcRoutine.profileID,
            name: vcRoutine.name,
            description: vcRoutine.description_p,
            actionIds: Array(vcRoutine.actionIds),
            enabled: vcRoutine.enabled,
            metadata: vcRoutine.metadata,
            createdAt: vcRoutine.hasCreatedAt ? vcRoutine.createdAt.date : Date(),
            updatedAt: vcRoutine.hasUpdatedAt ? vcRoutine.updatedAt.date : Date(),
            lastExecutedAt: vcRoutine.hasLastExecutedAt ? vcRoutine.lastExecutedAt.date : nil
        )
    }

    private func convertToVCRoutine(_ routine: Routine) -> VCRoutine {
        var vcRoutine = VCRoutine()
        vcRoutine.id = routine.id
        vcRoutine.profileID = routine.profileId
        vcRoutine.name = routine.name
        vcRoutine.description_p = routine.description
        vcRoutine.actionIds = routine.actionIds
        vcRoutine.enabled = routine.enabled
        vcRoutine.metadata = routine.metadata
        vcRoutine.createdAt = Google_Protobuf_Timestamp(date: routine.createdAt)
        vcRoutine.updatedAt = Google_Protobuf_Timestamp(date: routine.updatedAt)
        if let lastExecutedAt = routine.lastExecutedAt {
            vcRoutine.lastExecutedAt = Google_Protobuf_Timestamp(date: lastExecutedAt)
        }
        return vcRoutine
    }

    private func convertToExecutionLog(_ vcLog: VCExecutionLog) -> ExecutionLog {
        return ExecutionLog(
            logId: vcLog.logID,
            routineId: vcLog.routineID,
            timestamp: vcLog.hasTimestamp ? vcLog.timestamp.date : Date(),
            completed: vcLog.completed,
            notes: vcLog.notes,
            actionResults: vcLog.actionResults
        )
    }
}

// ExecutionLog model is defined in Models/ExecutionLog.swift