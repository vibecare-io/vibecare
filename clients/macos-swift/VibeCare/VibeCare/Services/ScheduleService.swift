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
        profileId: String,
        routineId: String,
        name: String,
        rrule: String,
        scheduleTimezone: String? = nil,
        dtstart: String,
        exdates: [String] = [],
        notes: String = "",
        enabled: Bool = true
    ) async throws -> Schedule {
        logger.info("Creating schedule: \(name)")

        let request = VCCreateScheduleRequest.with { req in
            req.id = id  // Client-provided UUID
            req.profileID = profileId
            req.routineID = routineId
            req.name = name
            req.rrule = rrule
            req.scheduleTimezone = scheduleTimezone ?? TimeZone.current.identifier  // Default to system timezone
            req.dtstart = dtstart
            req.exdates = exdates
            req.notes = notes
            req.enabled = enabled
            // actionIds removed - managed via schedule_actions join table
        }
        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.createSchedule(request)
        }

        logger.info("Schedule created successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,  // Use the UUID from server response
            profileId: response.profileID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            scheduleTimezone: response.scheduleTimezone,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            nextExecution: response.hasNextExecution ? response.nextExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            // actionIDs removed - managed via schedule_actions join table
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
            profileId: response.profileID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            scheduleTimezone: response.scheduleTimezone,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            nextExecution: response.hasNextExecution ? response.nextExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            // actionIDs removed - managed via schedule_actions join table
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
            req.scheduleTimezone = schedule.scheduleTimezone
            req.dtstart = ISO8601DateFormatter().string(from: schedule.dtstart)
            req.exdates = schedule.exdates
            req.notes = schedule.notes
            req.enabled = schedule.enabled
            req.routineID = schedule.routineId
            // actionIds removed - managed via schedule_actions join table
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.updateSchedule(request)
        }

        logger.info("Schedule updated successfully: \(response.name)")

        return Schedule(
            id: response.scheduleID,
            profileId: response.profileID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            scheduleTimezone: response.scheduleTimezone,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            nextExecution: response.hasNextExecution ? response.nextExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            // actionIDs removed - managed via schedule_actions join table
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
                profileId: schedule.profileID,
                routineId: schedule.routineID,
                name: schedule.name,
                rrule: schedule.rrule,
                scheduleTimezone: schedule.scheduleTimezone,
                dtstart: schedule.dtstart.date,
                exdates: schedule.exdates,
                lastExecution: schedule.hasLastExecution ? schedule.lastExecution.date : nil,
                nextExecution: schedule.hasNextExecution ? schedule.nextExecution.date : nil,
                notes: schedule.notes,
                enabled: schedule.enabled,
                // actionIDs removed - managed via schedule_actions join table
                createdAt: schedule.createdAt.date,
                updatedAt: schedule.updatedAt.date
            )
        }
    }

    nonisolated func listAllSchedules(for profileId: String) async throws -> [Schedule] {
        logger.info("Listing all schedules for profile: \(profileId)")

        // First, get all routines for the profile
        let routineService = RoutineService()
        let routines = try await routineService.listRoutines(for: profileId)

        logger.info("Found \(routines.count) routines for profile: \(profileId)")

        // Then, aggregate all schedules from all routines
        var allSchedules: [Schedule] = []
        for routine in routines {
            let schedules = try await listSchedules(for: routine.id)
            allSchedules.append(contentsOf: schedules)
        }

        logger.info("Listed \(allSchedules.count) total schedules for profile: \(profileId)")
        return allSchedules
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
            profileId: response.profileID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            scheduleTimezone: response.scheduleTimezone,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            nextExecution: response.hasNextExecution ? response.nextExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            // actionIDs removed - managed via schedule_actions join table
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
            profileId: response.profileID,
            routineId: response.routineID,
            name: response.name,
            rrule: response.rrule,
            scheduleTimezone: response.scheduleTimezone,
            dtstart: response.dtstart.date,
            exdates: response.exdates,
            lastExecution: response.hasLastExecution ? response.lastExecution.date : nil,
            nextExecution: response.hasNextExecution ? response.nextExecution.date : nil,
            notes: response.notes,
            enabled: response.enabled,
            // actionIDs removed - managed via schedule_actions join table
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

    // MARK: - Schedule-Action Association Methods

    nonisolated func getScheduleActions(scheduleId: String) async throws -> [String] {
        logger.info("Getting actions for schedule: \(scheduleId)")

        let request = VCGetScheduleActionsRequest.with { req in
            req.scheduleID = scheduleId
        }

        let response = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.getScheduleActions(request)
        }

        logger.info("Retrieved \(response.actionIds.count) actions for schedule: \(scheduleId)")
        return Array(response.actionIds)
    }

    nonisolated func addActionToSchedule(scheduleId: String, actionId: String, order: Int) async throws {
        logger.info("Adding action \(actionId) to schedule \(scheduleId) at order \(order)")

        let request = VCAddActionToScheduleRequest.with { req in
            req.scheduleID = scheduleId
            req.actionID = actionId
            req.actionOrder = Int32(order)
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.addActionToSchedule(request)
        }

        logger.info("Successfully added action to schedule")
    }

    nonisolated func removeActionFromSchedule(scheduleId: String, actionId: String) async throws {
        logger.info("Removing action \(actionId) from schedule \(scheduleId)")

        let request = VCRemoveActionFromScheduleRequest.with { req in
            req.scheduleID = scheduleId
            req.actionID = actionId
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.removeActionFromSchedule(request)
        }

        logger.info("Successfully removed action from schedule")
    }

    nonisolated func updateScheduleActionOrder(scheduleId: String, actionId: String, newOrder: Int) async throws {
        logger.info("Updating action \(actionId) order to \(newOrder) in schedule \(scheduleId)")

        let request = VCUpdateScheduleActionOrderRequest.with { req in
            req.scheduleID = scheduleId
            req.actionID = actionId
            req.newOrder = Int32(newOrder)
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.updateScheduleActionOrder(request)
        }

        logger.info("Successfully updated action order")
    }

    nonisolated func replaceScheduleActions(scheduleId: String, actionIds: [String]) async throws {
        logger.info("Replacing actions for schedule \(scheduleId) with \(actionIds.count) actions")

        let request = VCReplaceScheduleActionsRequest.with { req in
            req.scheduleID = scheduleId
            req.actionIds = actionIds
        }

        _ = try await GRPCClientManager.shared.withScheduleServiceClient { client in
            return try await client.replaceScheduleActions(request)
        }

        logger.info("Successfully replaced schedule actions")
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
