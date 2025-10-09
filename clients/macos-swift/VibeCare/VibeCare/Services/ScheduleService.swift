import Foundation
import Logging
import VCStubs

class ScheduleService: @unchecked Sendable {
    private let logger = Logger(label: "com.vibecare.schedule-service")

    init() {
        logger.info("ScheduleService initialized")
    }

    // MARK: - Schedule CRUD Operations

    nonisolated func createSchedule(
        id: String,
        routineId: String,
        name: String,
        rrule: String,
        dtstart: String,
        exdates: [String] = [],
        notes: String = "",
        enabled: Bool = true
    ) async throws -> Schedule {
        logger.info("Creating schedule: \(name)")

        let request = VCCreateScheduleRequest.with { req in
            req.id = id  // Client-provided UUID
            req.routineID = routineId
            req.name = name
            req.rrule = rrule
            req.dtstart = dtstart
            req.exdates = exdates
            req.notes = notes
            req.enabled = enabled
        }
        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.createSchedule(request)
        }

        logger.info("Schedule created successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,  // Use the UUID from server response
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            createdAt: response.createdAt.date,
            updatedAt: response.updatedAt.date
        )
    }

    nonisolated func getSchedule(id: String) async throws -> Schedule? {
        logger.info("Fetching schedule: \(id)")

        let request = VCGetScheduleRequest.with { req in
            req.scheduleID = id
        }
        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.getSchedule(request)
        }

        logger.info("Schedule fetched successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            createdAt: response.createdAt.date,
            updatedAt: response.updatedAt.date
        )
    }

    nonisolated func updateSchedule(_ schedule: Schedule) async throws -> Schedule {
        logger.info("Updating schedule: \(schedule.name)")

        let request = VCUpdateScheduleRequest.with { req in
            req.scheduleID = schedule.id
            req.name = schedule.name
            req.rrule = schedule.rrule
            req.dtstart = ISO8601DateFormatter().string(from: schedule.dtstart)
            req.exdates = schedule.exdates
            req.notes = schedule.notes
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.updateSchedule(request)
        }

        logger.info("Schedule updated successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            createdAt: response.createdAt.date,
            updatedAt: response.updatedAt.date
        )
    }

    nonisolated func deleteSchedule(id: String) async throws {
        logger.info("Deleting schedule: \(id)")

        let request = VCDeleteScheduleRequest.with { req in
            req.scheduleID = id
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.deleteSchedule(request)
        }

        logger.info("Schedule deleted successfully: \(id)")
    }

    nonisolated func listSchedules(for routineId: String) async throws -> [Schedule] {
        logger.info("Listing schedules for routine: \(routineId)")

        let request = VCListSchedulesRequest.with { req in
            req.routineID = routineId
            req.enabledOnly = false
            req.pageSize = 100 // Reasonable default
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.listSchedules(request)
        }

        logger.info("Listed \(response.schedules.count) schedules for routine: \(routineId)")

        return response.schedules.map { schedule in
            Schedule(
                id: schedule.scheduleID,
                routineId: schedule.routineID,
                name: schedule.name,
                rrule: schedule.rrule,
                dtstart: schedule.dtstart.date,
                exdates: schedule.exdates,
                lastExecution: schedule.hasLastExecution ? schedule.lastExecution.date : nil,
                notes: schedule.notes,
                enabled: schedule.enabled,
                createdAt: schedule.createdAt.date,
                updatedAt: schedule.updatedAt.date
            )
        }
    }

    // MARK: - Schedule Operations

    nonisolated func getNextExecution(scheduleId: String) async throws -> Date? {
        logger.info("Getting next execution for schedule: \(scheduleId)")

        let request = VCGetNextExecutionRequest.with { req in
            req.scheduleID = scheduleId
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.getNextExecution(request)
        }

        return response.hasNextExecution ? response.nextExecution.date : nil
    }

    nonisolated func pauseSchedule(scheduleId: String, durationMinutes: Int = 0) async throws -> Schedule {
        logger.info("Pausing schedule: \(scheduleId)")

        let request = VCPauseScheduleRequest.with { req in
            req.scheduleID = scheduleId
            req.durationMinutes = Int32(durationMinutes)
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.pauseSchedule(request)
        }

        logger.info("Schedule paused successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            createdAt: response.createdAt.date,
            updatedAt: response.updatedAt.date
        )
    }

    nonisolated func resumeSchedule(scheduleId: String) async throws -> Schedule {
        logger.info("Resuming schedule: \(scheduleId)")

        let request = VCResumeScheduleRequest.with { req in
            req.scheduleID = scheduleId
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.resumeSchedule(request)
        }

        logger.info("Schedule resumed successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            createdAt: response.createdAt.date,
            updatedAt: response.updatedAt.date
        )
    }

    // MARK: - Bulk Operations

    nonisolated func pauseAllSchedules(profileId: String, durationMinutes: Int = 0) async throws {
        logger.info("Pausing all schedules for profile: \(profileId)")

        let request = VCPauseAllSchedulesRequest.with { req in
            req.profileID = profileId
            req.durationMinutes = Int32(durationMinutes)
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.pauseAllSchedules(request)
        }

        logger.info("All schedules paused for profile: \(profileId)")
    }

    nonisolated func resumeAllSchedules(profileId: String) async throws {
        logger.info("Resuming all schedules for profile: \(profileId)")

        let request = VCResumeAllSchedulesRequest.with { req in
            req.profileID = profileId
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.resumeAllSchedules(request)
        }

        logger.info("All schedules resumed for profile: \(profileId)")
    }

}

// MARK: - Helper Extensions

// Note: These extensions will need to be updated once protobuf stubs are regenerated
// The current implementation assumes the existing protobuf structure needs updates
//
// extension VCSchedule {
//     var id: String {
//         return String(scheduleID)
//     }
// }
