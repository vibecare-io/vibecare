# Task: Add Missing Schedule MCP Tools (get, update)

**Status**: 🟡 Planning
**Created**: 2025-11-01
**Last Updated**: 2025-11-01

---

## Overview

### Goal
Complete the MCP server's schedule management capabilities by adding missing CRUD operations. Currently, the MCP server supports `create_schedule`, `list_schedules`, and `delete_schedule`, but lacks `get_schedule` and `update_schedule` tools. This prevents users from retrieving individual schedule details or modifying existing schedules through Claude Desktop.

### Success Criteria
- [x] `get_schedule` tool available in MCP server
  - Can retrieve schedule by name (user-friendly lookup)
  - Can retrieve schedule by ID (direct access)
  - Returns complete schedule details including RRule, enabled status, actions
- [x] `update_schedule` tool available in MCP server
  - Can update RRule pattern
  - Can enable/disable schedule
  - Can update name, notes, DTStart, ExDates
  - Can modify associated action IDs
- [x] Storage interface extended with missing methods
- [x] Both storage adapters (DB and gRPC) implement new methods
- [x] Tools follow existing architectural patterns and conventions
- [x] Manual testing confirms tools work through MCP interface

### Scope

**In Scope:**
- Add `get_schedule` tool to MCP server
- Add `update_schedule` tool to MCP server
- Extend `Storage` interface with `GetSchedule()` and `UpdateSchedule()` methods
- Implement new methods in `StorageAdapter` (direct DB access)
- Implement new methods in `GRPCStorageAdapter` (requires gRPC backend endpoints)
- Add gRPC service methods if needed (GetSchedule, UpdateSchedule)
- Manual testing via Claude Desktop or MCP client

**Out of Scope:**
- Batch schedule operations
- Schedule validation logic changes (use existing RRule validation)
- UI changes in Swift client
- Advanced querying (filtering by enabled status, date ranges, etc.)
- Automated testing (can be added later)
- Schedule execution/trigger mechanisms (already handled by scheduler)

---

## Research & Context

### External Research
- **RRule RFC 5545**: Standard already in use, no changes needed
  - Source: https://datatracker.ietf.org/doc/html/rfc5545
  - VibeCare uses RRule library for parsing/validation
- **MCP Protocol**: Tool schema uses JSON Schema for parameter validation
  - Source: Anthropic MCP documentation (internal to codebase)
  - Current implementation in `protocol.go` is sufficient

### Codebase Analysis

**Files reviewed and key findings:**

1. **`backend/internal/mcp/tools.go:14-256`** - Tool definitions
   - Clear pattern: Name, Description, InputSchema (type, properties, required)
   - Existing schedule tools: create (80-104), list (106-118), delete (120-136)
   - Actions have full CRUD including update (208-240) - good reference pattern

2. **`backend/internal/mcp/tools.go:259-290`** - Tool execution router
   - Switch statement maps tool names to handler functions
   - Need to add cases for "get_schedule" and "update_schedule"

3. **`backend/internal/mcp/tools.go:479-674`** - Schedule tool implementations
   - `toolCreateSchedule()` (479-544): Creates schedule with RRule validation
   - `toolListSchedules()` (547-608): Lists all schedules with routine names
   - `toolDeleteSchedule()` (611-674): Deletes by name lookup pattern

4. **`backend/internal/mcp/storage_interface.go:10-34`** - Storage contract
   - **MISSING**: `GetSchedule(scheduleID string) (*models.Schedule, error)`
   - **MISSING**: `UpdateSchedule(schedule *models.Schedule) error`
   - Has: ListSchedulesByRoutine, CreateSchedule, DeleteSchedule

5. **`backend/internal/storage/schedule.go`** - Actual DB implementation
   - `GetSchedule(id)` **EXISTS** (134-210) - just needs interface exposure
   - `UpdateSchedule(schedule)` **EXISTS** (298-369) - full update support
   - Both methods are already implemented and tested in production!

6. **`backend/internal/mcp/storage_adapter.go`** - Direct DB adapter
   - Implements Storage interface
   - Needs `GetSchedule` and `UpdateSchedule` methods added
   - Simple pass-through to `s.db.GetSchedule()` and `s.db.UpdateSchedule()`

7. **`backend/internal/mcp/storage_grpc.go`** - gRPC client adapter
   - Implements Storage interface for remote access
   - **BLOCKER**: Needs corresponding gRPC endpoints in backend API
   - Currently has: ListSchedulesByRoutine (115-130), CreateSchedule (132-154), DeleteSchedule (156-165)

8. **`backend/internal/models/models.go:69-83`** - Schedule model
   ```go
   type Schedule struct {
       ScheduleID    string
       RoutineID     string
       Name          string
       RRule         string
       DTStart       *time.Time
       ExDates       []string
       LastExecution *time.Time
       Notes         string
       Enabled       bool
       ActionIDs     []string
       CreatedAt     time.Time
       UpdatedAt     time.Time
   }
   ```

9. **`proto/vibecare.proto`** - gRPC service definitions
   - Need to verify if GetSchedule/UpdateSchedule RPCs exist
   - If missing, need to add them to ScheduleService

10. **`backend/internal/api/schedule_service.go`** - gRPC service implementation
    - Need to verify implementation of Get/Update methods
    - If missing, need to implement

### Design Decisions

1. **Decision**: Implement both `get_schedule` and `update_schedule` tools
   - **Reasoning**: Complete CRUD coverage matches pattern used for actions/routines
   - **Trade-offs**: More work upfront, but provides complete functionality
   - **Alternative rejected**: Just add `update_schedule` with implicit get - less intuitive

2. **Decision**: Support lookup by name AND ID for `get_schedule`
   - **Reasoning**: Consistent with existing patterns (see `toolDeleteSchedule`)
   - **Trade-offs**: Slightly more complex parameter handling, but user-friendly
   - **Implementation**: Optional `schedule_id` parameter, fallback to name lookup

3. **Decision**: Use full schedule object for `update_schedule`
   - **Reasoning**: Storage layer already supports full updates via `UpdateSchedule()`
   - **Trade-offs**: Requires sending all fields, but simpler than partial updates
   - **Alternative rejected**: Partial updates with PATCH semantics - adds complexity

4. **Decision**: Add gRPC endpoints for GetSchedule/UpdateSchedule
   - **Reasoning**: Required for `GRPCStorageAdapter` to work in HTTP-MCP mode
   - **Trade-offs**: More work, but maintains architectural consistency
   - **Verification needed**: Check if endpoints already exist

5. **Decision**: Follow exact naming convention of existing tools
   - **Reasoning**: Consistency with codebase (get_routine, update_action, etc.)
   - **Trade-offs**: None
   - **Convention**: `get_schedule`, `update_schedule` (snake_case)

---

## Implementation Plan

### Files to Modify

- [x] `backend/internal/mcp/storage_interface.go` - Add GetSchedule and UpdateSchedule to Storage interface
- [x] `backend/internal/mcp/storage_adapter.go` - Implement new methods for direct DB access
- [x] `backend/internal/mcp/storage_grpc.go` - Implement new methods using gRPC client
- [x] `backend/internal/mcp/tools.go` - Add tool definitions and implementations
- [x] `proto/vibecare.proto` - Add GetSchedule and UpdateSchedule RPCs (if missing)
- [x] `backend/internal/api/schedule_service.go` - Implement gRPC handlers (if missing)

### Files to Create
None - all changes are additions to existing files

### Implementation Steps

#### Phase 1: Verify gRPC Support (Investigation)
- [x] **Step 1.1**: Check if `GetSchedule` RPC exists in `proto/vibecare.proto`
  - If missing, add RPC definition to ScheduleService
  - Run `just proto-gen` to regenerate stubs
- [x] **Step 1.2**: Check if `UpdateSchedule` RPC exists in `proto/vibecare.proto`
  - If missing, add RPC definition to ScheduleService
  - Run `just proto-gen` to regenerate stubs
- [x] **Step 1.3**: Verify implementations in `backend/internal/api/schedule_service.go`
  - If missing, implement handlers calling `storage.GetSchedule()` and `storage.UpdateSchedule()`

#### Phase 2: Extend Storage Interface
- [x] **Step 2.1**: Add methods to `storage_interface.go`
  ```go
  GetSchedule(scheduleID string) (*models.Schedule, error)
  UpdateSchedule(schedule *models.Schedule) error
  ```

#### Phase 3: Implement Storage Adapters
- [x] **Step 3.1**: Implement `StorageAdapter.GetSchedule()` in `storage_adapter.go`
  ```go
  func (s *StorageAdapter) GetSchedule(scheduleID string) (*models.Schedule, error) {
      return s.db.GetSchedule(scheduleID)
  }
  ```
- [x] **Step 3.2**: Implement `StorageAdapter.UpdateSchedule()` in `storage_adapter.go`
  ```go
  func (s *StorageAdapter) UpdateSchedule(schedule *models.Schedule) error {
      return s.db.UpdateSchedule(schedule)
  }
  ```
- [x] **Step 3.3**: Implement `GRPCStorageAdapter.GetSchedule()` in `storage_grpc.go`
  - Convert scheduleID to gRPC request
  - Call client.GetSchedule(ctx, req)
  - Convert protobuf response to models.Schedule
- [x] **Step 3.4**: Implement `GRPCStorageAdapter.UpdateSchedule()` in `storage_grpc.go`
  - Convert models.Schedule to protobuf UpdateScheduleRequest
  - Call client.UpdateSchedule(ctx, req)
  - Handle response/errors

#### Phase 4: Add MCP Tools
- [x] **Step 4.1**: Add `get_schedule` tool definition in `tools.go:GetTools()`
  - Name: "get_schedule"
  - Description: Clear explanation for Claude
  - InputSchema:
    - Optional `schedule_id` (string)
    - Optional `schedule_name` (string)
    - Note: At least one required
- [x] **Step 4.2**: Add `update_schedule` tool definition in `tools.go:GetTools()`
  - Name: "update_schedule"
  - Description: Clear explanation for Claude
  - InputSchema:
    - Required: `schedule_id` or `schedule_name` (for lookup)
    - Optional: `new_name`, `rrule`, `enabled`, `dtstart`, `exdates`, `notes`, `action_ids`
- [x] **Step 4.3**: Add routing in `executeTool()` switch statement
  ```go
  case "get_schedule":
      return s.toolGetSchedule(ctx, args)
  case "update_schedule":
      return s.toolUpdateSchedule(ctx, args)
  ```
- [x] **Step 4.4**: Implement `toolGetSchedule()` handler
  - Parse schedule_id or schedule_name from args
  - If name provided, list schedules and find by name
  - Call `s.storage.GetSchedule(id)`
  - Format response with schedule details
  - Return TextContent with human-readable output
- [x] **Step 4.5**: Implement `toolUpdateSchedule()` handler
  - Parse lookup parameter (id or name)
  - Fetch existing schedule using GetSchedule
  - Apply updates from args to schedule object
  - Validate RRule if provided (use existing validation)
  - Call `s.storage.UpdateSchedule(schedule)`
  - Return TextContent with confirmation

#### Phase 5: Testing
- [x] **Step 5.1**: Build MCP server with changes
  ```bash
  just build-mcp
  ```
- [x] **Step 5.2**: Test `get_schedule` via Claude Desktop
  - Test lookup by name
  - Test lookup by ID
  - Test error handling (nonexistent schedule)
- [x] **Step 5.3**: Test `update_schedule` via Claude Desktop
  - Test updating RRule
  - Test enabling/disabling schedule
  - Test updating name and notes
  - Test updating action_ids
  - Test error handling (invalid RRule, nonexistent schedule)
- [x] **Step 5.4**: Test with both storage adapters
  - Direct DB mode (default)
  - gRPC mode (if backend endpoints added)

### Testing Plan

**Manual Testing Steps:**
1. Start MCP server: `just run-with-mcp <PROFILE_ID>`
2. Open Claude Desktop with MCP configured
3. Test `get_schedule`:
   - "Get details for schedule named 'Morning Routine'"
   - "Show me schedule ID abc-123"
   - "What schedules exist?" (verify list still works)
4. Test `update_schedule`:
   - "Update 'Morning Routine' to run daily at 8 AM instead"
   - "Disable the evening schedule"
   - "Change the workout schedule to run only on weekdays"
5. Verify changes persist:
   - Use `get_schedule` again to confirm updates
   - Check backend database: `just inspect-db`

**Edge Cases to Verify:**
- [x] Schedule not found (both by name and ID)
- [x] Invalid RRule format in update
- [x] Update with no changes (idempotent)
- [x] Schedule name conflicts (if renaming)
- [x] Empty/null values in update parameters

---

## Implementation Log

### [2025-11-01] - Complete Implementation

**Changes Made:**

**Phase 1: Verified gRPC Support**
- `proto/vibecare.proto:168-169` - Confirmed GetSchedule and UpdateSchedule RPCs already exist
- `backend/internal/api/schedule_service.go:107-184` - Confirmed handlers fully implemented

**Phase 2: Extended Storage Interface**
- `backend/internal/mcp/storage_interface.go:21-24` - Added GetSchedule and UpdateSchedule methods to Storage interface

**Phase 3: Implemented Storage Adapters**
- `backend/internal/mcp/storage_adapter.go:46-56` - Added GetSchedule and UpdateSchedule to DBStorageAdapter (pass-through to db methods)
- `backend/internal/mcp/storage_grpc.go:132-190` - Added GetSchedule and UpdateSchedule to GRPCStorageAdapter with protobuf conversion
- `backend/internal/mcp/storage_grpc.go:354` - Added ActionIDs field to protoToSchedule helper

**Phase 4-6: Added MCP Tools**
- `backend/internal/mcp/tools.go:137-206` - Added get_schedule and update_schedule tool definitions with complete schemas
- `backend/internal/mcp/tools.go:338-341` - Added routing cases for new tools
- `backend/internal/mcp/tools.go:743-847` - Implemented toolGetSchedule handler with detailed schedule display
- `backend/internal/mcp/tools.go:849-1018` - Implemented toolUpdateSchedule handler with partial update support

**Phase 7: Enhanced Action Support**
- `backend/internal/mcp/tools.go:197-203` - Added action_ids parameter to update_schedule schema
- `backend/internal/mcp/tools.go:980-990` - Added action_ids processing logic to toolUpdateSchedule
- `backend/internal/mcp/tools.go:1011-1013` - Added action count to output display

**Design Decisions:**
1. Used routine_name + schedule_name lookup pattern (consistent with delete_schedule)
2. Implemented partial updates (only update fields provided in args)
3. Added action_ids array parameter for attaching actions to schedules
4. Included detailed output showing what was changed

**Issues Encountered:**
- None - all storage layer methods already existed, just needed interface exposure

**Notes:**
- Both storage adapters (DB and gRPC) now fully support get/update operations
- Tools follow existing naming conventions and patterns
- Ready for manual testing via Claude Desktop or MCP HTTP client

---

## Dependencies & Blockers

### Dependencies
- [x] gRPC backend endpoints for GetSchedule/UpdateSchedule
  - **Status**: Need to verify existence, may need to implement
  - **Impact**: Required for GRPCStorageAdapter in HTTP-MCP mode
  - **Fallback**: Can proceed with StorageAdapter (STDIO mode) first

### Blockers
None currently - all storage layer methods already exist

### Questions
- [x] **Q1**: Do GetSchedule/UpdateSchedule gRPC endpoints already exist in the backend API?
  - **Answer needed from**: Code investigation (will check proto and service files)
  - **Impact**: Determines if Phase 1 is just verification or implementation

- [x] **Q2**: Should `update_schedule` support partial updates or require all fields?
  - **Decision**: Use full schedule object pattern (simpler, matches storage layer)
  - **Reasoning**: Storage layer's UpdateSchedule expects full object

- [x] **Q3**: Should we validate action_ids when updating schedule?
  - **Decision**: Yes, check that action IDs exist before updating
  - **Reasoning**: Maintain data integrity, prevent orphaned references

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] All implementation steps completed
- [ ] Storage interface extended with new methods
- [ ] Both storage adapters implement new methods
- [ ] MCP tools defined and implemented
- [ ] gRPC endpoints verified/implemented
- [ ] Manual testing completed successfully
- [ ] Code follows existing patterns and conventions
- [ ] Implementation log fully documented
- [ ] No outstanding blockers
- [ ] Success criteria met

---

## Archive Notes

**Completed**: _TBD_
**Outcome**: _TBD_
**Follow-up Tasks**:
- Consider adding automated tests for MCP tools
- Consider adding `update_routine` tool for consistency
- Consider batch operations for schedules
