# Simplify Database Schema

**Status**: 🔵 In Progress
**Started**: 2025-11-05
**Goal**: Simplify database by removing JSON fields and using proper join tables with CASCADE DELETE

## Context
Current schema has unnecessary complexity with JSON fields storing action associations. We need:
- Remove JSON fields (actions_json, action_ids) from routines and schedules
- Add schedule_actions join table with CASCADE DELETE
- Add profile_id to schedules table
- Remove execution_logs table entirely
- Keep routines as simple metadata containers

## Current Schema Issues
1. routines: redundant `actions_json` + `action_ids` JSON fields
2. schedules: `action_ids` JSON instead of join table
3. schedules: missing `profile_id` - only accessible through routine
4. execution_logs: table exists but not needed
5. No CASCADE DELETE for action relationships

## Proposed Schema

### routines (simplified):
```sql
- Remove: actions_json, action_ids
- Keep: id, profile_id, name, description, enabled, metadata, last_executed_at
```

### schedules (add profile_id, remove JSON):
```sql
- Add: profile_id with FK CASCADE
- Remove: action_ids
```

### schedule_actions (NEW join table):
```sql
CREATE TABLE schedule_actions (
    schedule_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    action_order INTEGER NOT NULL,
    PRIMARY KEY (schedule_id, action_id),
    FOREIGN KEY (schedule_id) REFERENCES schedules(schedule_id) ON DELETE CASCADE,
    FOREIGN KEY (action_id) REFERENCES actions(action_id) ON DELETE CASCADE
);
```

### execution_logs:
```sql
- DROP TABLE entirely
```

## Plan

### Phase 1: Database Migration
- [ ] Create migration file `007_simplify_schema.sql`
- [ ] Create schedule_actions join table
- [ ] Migrate data from schedules.action_ids JSON to schedule_actions
- [ ] Add profile_id to schedules (copy from routines)
- [ ] Drop actions_json and action_ids from routines
- [ ] Drop action_ids from schedules
- [ ] Drop execution_logs table
- [ ] Add indexes for schedule_actions

### Phase 2: Go Backend
- [ ] Update `models/models.go` - remove JSON fields, add ScheduleAction struct
- [ ] Update `storage/routine.go` - remove action_ids handling
- [ ] Update `storage/schedule.go` - add profile_id, use join table
- [ ] Add `storage/schedule_action.go` - CRUD for join table
- [ ] Delete `storage/execution_log.go`
- [ ] Update `api/routine_service.go`
- [ ] Update `api/schedule_service.go` - add profile_id
- [ ] Remove execution log API if exists

### Phase 3: Protocol Buffers
- [ ] Update `proto/vibecare.proto` - add profile_id to Schedule
- [ ] Remove execution log messages if any
- [ ] Regenerate: `just proto-gen`

### Phase 4: Swift Client
- [ ] Update Schedule model with profile_id
- [ ] Update ScheduleService to send profile_id
- [ ] Remove execution log code
- [ ] Update local storage for new schema

### Phase 5: Testing
- [ ] Test schedule creation with actions
- [ ] Test CASCADE DELETE behavior
- [ ] Verify data migration
- [ ] Test routine/schedule/action CRUD operations

## Implementation Log
_Will be updated as work progresses_

## Dependencies
- Must backup database before migration
- Breaking change - requires careful data migration

## Deferred Items
- None yet

## Notes for Handoff
- Routines are now just metadata containers
- schedules → actions relationship via join table
- CASCADE DELETE automatically cleans up orphaned records
