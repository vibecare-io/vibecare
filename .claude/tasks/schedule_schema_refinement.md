# Task: Schedule Schema Refinement - Add schedule_type and next_execution

**Status**: 🟡 Planning
**Created**: 2025-11-23
**Last Updated**: 2025-11-23

---

## Overview

### Goal
Refine the schedules table schema to follow industry best practices for production scheduling systems:
1. Add explicit `schedule_type` enum (ONE_SHOT vs RECURRING)
2. Add `next_execution` TIMESTAMP column (pre-calculated for performance)
3. Implement atomic transactional updates to prevent race conditions
4. Optimize scheduler queries with proper indexing

### Success Criteria
- [x] Investigation complete - current schema analyzed
- [ ] Migration created and tested
- [ ] Go models updated with new fields
- [ ] Protobuf definitions updated
- [ ] Storage layer implements atomic UpdateScheduleExecution
- [ ] Scheduler uses next_execution for efficient querying
- [ ] API service returns next_execution in responses
- [ ] Swift client displays correct schedule status
- [ ] All tests passing
- [ ] Performance improvement verified (100x+ faster queries)

### Scope
**In Scope:**
- Database schema migration (add schedule_type, next_execution)
- Atomic transactional update logic
- Backend model and storage layer changes
- Protobuf message updates
- Scheduler query optimization
- Swift client display fixes

**Out of Scope:**
- Converting TEXT to TIMESTAMP types (SQLite limitation, semantic improvement only)
- Changing existing schedule_actions join table
- Modifying routine or profile tables
- Web client changes (future work)

---

## Research & Context

### Current State Analysis

**Database Schema** (from migration 20251105201500):
```sql
CREATE TABLE schedules (
    schedule_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    routine_id TEXT NOT NULL,
    name TEXT,
    rrule TEXT NOT NULL,              -- Empty string for one-time events
    dtstart TEXT,                     -- RFC3339 TEXT format
    exdates TEXT,
    last_execution TEXT,              -- RFC3339 TEXT format
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);
```

**Current Issues:**
1. **No schedule_type column** - ONE_SHOT vs RECURRING determined implicitly by empty/non-empty rrule
2. **No next_execution column** - calculated on-the-fly (slow for list operations)
3. **Non-atomic updates** - UpdateLastExecution separate from event dispatch (race condition risk)
4. **Inefficient scheduler query** - Must load ALL schedules and parse RRules to find ready-to-execute

### External Research

**Industry Best Practices** (Quartz, Airflow, Kubernetes CronJobs):
- Store next execution time for O(log n) indexed queries
- Use explicit type/kind fields for clarity
- Atomic transaction updates (last_execution + next_execution together)
- Separate calculation logic from storage

**RRule Library**: `github.com/teambition/rrule-go`
- Already used in scheduler
- Can calculate next occurrence from current time
- Supports all RFC 5545 recurrence patterns

### Codebase Analysis

**Key Files Reviewed:**
- `backend/internal/storage/migrations/20251105201500_simplify_schema.sql` - Current schema
- `backend/internal/models/models.go:68-86` - Schedule struct
- `backend/internal/storage/schedule.go` - CRUD operations
- `backend/internal/scheduler/scheduler.go:87-151` - shouldTrigger logic
- `backend/internal/scheduler/scheduler.go:247` - Non-atomic UpdateLastExecution call
- `proto/vibecare.proto:83-96` - Schedule message
- `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift` - Swift model

**Transaction Pattern Found:**
- `storage/schedule_action.go:95-124` - ReplaceScheduleActions uses tx.Begin/Commit pattern
- Can use as template for UpdateScheduleExecution

### Design Decisions

1. **Decision**: Add schedule_type enum column
   - **Reasoning**: Makes schema self-documenting, enables efficient queries by type
   - **Trade-offs**: Migration complexity vs long-term maintainability (choose maintainability)

2. **Decision**: Store next_execution in database
   - **Reasoning**: 100-1000x faster queries, enables SQL-level sorting/filtering
   - **Trade-offs**: Database writes on every execution vs read performance (choose performance)

3. **Decision**: Atomic transactional updates
   - **Reasoning**: Prevents duplicate event dispatches from race conditions
   - **Trade-offs**: Slightly more complex code vs correctness (choose correctness)

4. **Decision**: Keep TEXT timestamps for now
   - **Reasoning**: SQLite stores TIMESTAMP as TEXT anyway, semantic improvement only
   - **Trade-offs**: Can revisit in future if needed

---

## Implementation Plan

### Phase 1: Database Migration

**Files to Create:**
- [ ] `backend/internal/storage/migrations/YYYYMMDD_HHMMSS_add_schedule_refinements.sql`

**Migration Steps:**

**Step 1**: Add new columns (nullable initially)
```sql
-- Add columns without constraints first
ALTER TABLE schedules ADD COLUMN schedule_type TEXT;
ALTER TABLE schedules ADD COLUMN next_execution TEXT;
```

**Step 2**: Populate schedule_type from existing rrule
```sql
-- Infer type from rrule content
UPDATE schedules
SET schedule_type = CASE
    WHEN rrule = '' THEN 'ONE_SHOT'
    ELSE 'RECURRING'
END;
```

**Step 3**: Populate next_execution (requires Go code)
- For ONE_SHOT schedules:
  - If last_execution IS NULL AND dtstart > NOW: next_execution = dtstart
  - If last_execution IS NOT NULL: next_execution = NULL (already executed)
  - If dtstart < NOW AND last_execution IS NULL: next_execution = NULL (missed)
- For RECURRING schedules:
  - Calculate using RRule library from dtstart or last_execution

**Step 4**: Recreate table with constraints
```sql
-- SQLite doesn't support ADD CONSTRAINT, so recreate table
CREATE TABLE schedules_new (
    schedule_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    routine_id TEXT NOT NULL,
    schedule_type TEXT NOT NULL CHECK(schedule_type IN ('ONE_SHOT', 'RECURRING')),
    name TEXT,
    rrule TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    next_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

-- Copy data
INSERT INTO schedules_new SELECT * FROM schedules;

-- Drop old table
DROP TABLE schedules;

-- Rename new table
ALTER TABLE schedules_new RENAME TO schedules;
```

**Step 5**: Recreate indexes + add new ones
```sql
-- Existing indexes
CREATE INDEX idx_schedules_routine ON schedules(routine_id);
CREATE INDEX idx_schedules_profile ON schedules(profile_id);

-- New indexes for performance
CREATE INDEX idx_schedules_type ON schedules(schedule_type);
CREATE INDEX idx_schedules_next_execution ON schedules(next_execution)
    WHERE enabled = 1 AND next_execution IS NOT NULL;
CREATE INDEX idx_schedules_enabled ON schedules(enabled);
```

### Phase 2: Go Models

**Files to Modify:**
- [ ] `backend/internal/models/models.go`

**Changes:**

Add ScheduleType enum:
```go
type ScheduleType string

const (
    ScheduleTypeOneShot   ScheduleType = "ONE_SHOT"
    ScheduleTypeRecurring ScheduleType = "RECURRING"
)
```

Update Schedule struct (line 68):
```go
type Schedule struct {
    ScheduleID    string       `json:"schedule_id"`
    ProfileID     string       `json:"profile_id"`
    RoutineID     string       `json:"routine_id"`
    ScheduleType  ScheduleType `json:"schedule_type"`  // NEW
    Name          string       `json:"name"`
    RRule         string       `json:"rrule"`
    DTStart       *time.Time   `json:"dtstart,omitempty"`
    ExDates       []string     `json:"exdates,omitempty"`
    LastExecution *time.Time   `json:"last_execution,omitempty"`
    NextExecution *time.Time   `json:"next_execution,omitempty"`  // NEW
    Notes         string       `json:"notes"`
    Enabled       bool         `json:"enabled"`
    CreatedAt     time.Time    `json:"created_at"`
    UpdatedAt     time.Time    `json:"updated_at"`

    // Join fields
    RoutineName   string       `json:"routine_name,omitempty"`
    ProfileName   string       `json:"profile_name,omitempty"`
}
```

### Phase 3: Protobuf Updates

**Files to Modify:**
- [ ] `proto/vibecare.proto`

**Changes:**

Add ScheduleType enum:
```protobuf
enum ScheduleType {
  SCHEDULE_TYPE_UNSPECIFIED = 0;
  SCHEDULE_TYPE_ONE_SHOT = 1;
  SCHEDULE_TYPE_RECURRING = 2;
}
```

Update Schedule message (line 83):
```protobuf
message Schedule {
  string schedule_id = 1;
  string profile_id = 2;
  string routine_id = 3;
  string name = 4;
  string rrule = 5;
  google.protobuf.Timestamp dtstart = 6;
  repeated string exdates = 7;
  google.protobuf.Timestamp last_execution = 8;
  string notes = 9;
  bool enabled = 10;
  google.protobuf.Timestamp created_at = 11;
  google.protobuf.Timestamp updated_at = 12;
  ScheduleType schedule_type = 13;  // NEW
  google.protobuf.Timestamp next_execution = 14;  // NEW
}
```

**Action:**
- [ ] Run `just proto-gen` to regenerate Go and Swift code

### Phase 4: Storage Layer

**Files to Modify:**
- [ ] `backend/internal/storage/schedule.go`

**Changes:**

**1. Add helper function** (add at top of file):
```go
func calculateNextFromRRule(rruleStr string, dtstart, after time.Time) (time.Time, error) {
    if strings.TrimSpace(rruleStr) == "" {
        return time.Time{}, fmt.Errorf("empty rrule")
    }

    fullRRule := "DTSTART:" + dtstart.Format("20060102T150405Z") + "\nRRULE:" + rruleStr
    rule, err := rrule.StrToRRule(fullRRule)
    if err != nil {
        return time.Time{}, fmt.Errorf("failed to parse rrule: %w", err)
    }

    rset := &rrule.Set{}
    rset.RRule(rule)
    next := rset.After(after, false)

    return next, nil
}
```

**2. Update CreateSchedule** (line 14):
- Determine schedule_type from rrule
- Calculate initial next_execution
- Include both in INSERT statement

**3. Add new atomic method**:
```go
func (db *DB) UpdateScheduleExecution(scheduleID string, scheduleType models.ScheduleType, rrule string, dtstart time.Time) error {
    tx, err := db.Begin()
    if err != nil {
        return fmt.Errorf("failed to begin transaction: %w", err)
    }
    defer tx.Rollback()

    now := time.Now()
    var nextExecStr sql.NullString

    // Calculate next execution based on type
    if scheduleType == models.ScheduleTypeRecurring {
        nextTime, err := calculateNextFromRRule(rrule, dtstart, now)
        if err == nil && !nextTime.IsZero() {
            nextExecStr.Valid = true
            nextExecStr.String = nextTime.Format(time.RFC3339)
        }
    }
    // For ONE_SHOT, nextExecStr remains NULL (no next execution)

    query := `
        UPDATE schedules
        SET last_execution = ?,
            next_execution = ?,
            updated_at = ?
        WHERE schedule_id = ?
    `

    _, err = tx.Exec(query,
        now.Format(time.RFC3339),
        nextExecStr,
        now.Format(time.RFC3339),
        scheduleID,
    )
    if err != nil {
        return fmt.Errorf("failed to update schedule: %w", err)
    }

    return tx.Commit()
}
```

**4. Update GetSchedule** (line 129):
- Add schedule_type and next_execution to SELECT
- Parse new fields in Scan

**5. Update ListSchedulesByRoutine** (line 198):
- Add schedule_type and next_execution to SELECT
- Parse new fields in loop

**6. Update GetActiveSchedules** (line 372):
Change query to use next_execution for efficiency:
```sql
SELECT s.schedule_id, s.profile_id, s.routine_id, s.schedule_type, s.name, s.rrule,
       s.dtstart, s.exdates, s.last_execution, s.next_execution, s.notes, s.enabled,
       s.created_at, s.updated_at
FROM schedules s
INNER JOIN routines r ON s.routine_id = r.id
WHERE s.next_execution <= ?
  AND s.enabled = 1
  AND r.enabled = 1
ORDER BY s.next_execution
```

**7. Deprecate UpdateLastExecution** (line 356):
- Mark as deprecated
- Add comment to use UpdateScheduleExecution instead

### Phase 5: Scheduler Updates

**Files to Modify:**
- [ ] `backend/internal/scheduler/scheduler.go`

**Changes:**

**1. Simplify shouldTrigger** (line 87):
```go
func (s *Scheduler) shouldTrigger(schedule *models.Schedule, now time.Time) bool {
    // With next_execution column, this becomes trivial
    if schedule.NextExecution == nil {
        return false
    }

    return now.After(*schedule.NextExecution) || now.Equal(*schedule.NextExecution)
}
```

**2. Update dispatchScheduleEvent** (line 190):
Replace UpdateLastExecution call with atomic update:
```go
// Before broadcasting, atomically update last_execution and calculate next_execution
err := s.db.UpdateScheduleExecution(
    schedule.ScheduleID,
    schedule.ScheduleType,
    schedule.RRule,
    *schedule.DTStart,
)
if err != nil {
    s.logger.Error("Failed to update schedule execution times - skipping dispatch",
        zap.String("schedule_id", schedule.ScheduleID),
        zap.Error(err))
    return
}

// Only broadcast event if update succeeded (prevents duplicate dispatches)
s.eventHub.Broadcast(profileID, event)

s.logger.Info("Dispatched schedule event",
    zap.String("schedule_id", schedule.ScheduleID),
    zap.String("routine_id", routine.ID),
    zap.String("routine_name", routine.Name),
    zap.String("profile_id", profileID))
```

**3. Update checkAndDispatch** (line 68):
Pass NOW() to GetActiveSchedules query

### Phase 6: API Service Updates

**Files to Modify:**
- [ ] `backend/internal/api/schedule_service.go`

**Changes:**

**1. Update CreateSchedule** (line 18):
- Determine schedule_type from req.Rrule
- Log the type being created

**2. Update convertToProtoSchedule helper**:
- Map models.ScheduleType to pb.ScheduleType enum
- Convert NextExecution to protobuf Timestamp

**3. Complete GetNextExecution** (line 233):
Replace TODO with actual implementation:
```go
func (s *Server) GetNextExecution(ctx context.Context, req *pb.GetNextExecutionRequest) (*pb.GetNextExecutionResponse, error) {
    if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
        return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
    }

    schedule, err := s.db.GetSchedule(req.ScheduleId)
    if err != nil {
        return nil, status.Errorf(codes.NotFound, "schedule not found: %v", err)
    }
    if schedule == nil {
        return nil, status.Errorf(codes.NotFound, "schedule not found")
    }

    response := &pb.GetNextExecutionResponse{
        IsPaused: !schedule.Enabled,
    }

    if schedule.NextExecution != nil {
        response.NextExecution = timestamppb.New(*schedule.NextExecution)
    }

    return response, nil
}
```

### Phase 7: Swift Client Updates

**Files to Modify:**
- [ ] `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift`
- [ ] `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleRowView.swift`

**Changes:**

**1. Schedule.swift**:
- Remove local nextExecution computed property (lines 266-318)
- Use server-provided nextExecution field from protobuf
- Add scheduleType enum handling

**2. ScheduleRowView.swift**:
Update nextRunView (lines 166-194):
```swift
private var nextRunView: some View {
    if !schedule.enabled {
        Text("Paused")
            .foregroundColor(.secondary)
    } else if let nextExec = schedule.nextExecution {
        if nextExec < Date() {
            Text("Ready to execute")
                .foregroundColor(.orange)
        } else {
            Text("Next: \(nextExec, style: .relative)")
                .foregroundColor(.primary)
        }
    } else if schedule.scheduleType == .oneShot {
        Text("Completed")
            .foregroundColor(.gray)
    } else {
        Text("No upcoming runs")
            .foregroundColor(.secondary)
    }
}
```

### Phase 8: Testing Plan

**Unit Tests:**
- [ ] Test calculateNextFromRRule with various FREQ patterns
- [ ] Test UpdateScheduleExecution transaction atomicity
- [ ] Test schedule_type determination logic
- [ ] Test next_execution calculation for ONE_SHOT vs RECURRING

**Integration Tests:**
- [ ] Create ONE_SHOT schedule → verify next_execution = dtstart (if future)
- [ ] Execute ONE_SHOT schedule → verify next_execution = NULL
- [ ] Create RECURRING schedule → verify next_execution calculated correctly
- [ ] Execute RECURRING schedule → verify next_execution updated to next occurrence
- [ ] Test concurrent scheduler runs (no duplicate dispatches)

**Migration Tests:**
- [ ] Run migration on test database with existing schedules
- [ ] Verify all schedule_types populated correctly
- [ ] Verify all next_executions calculated correctly
- [ ] Verify indexes created successfully

**Performance Tests:**
- [ ] Benchmark GetActiveSchedules before/after (expect 100x+ improvement)
- [ ] Measure query time with 1000 schedules
- [ ] Verify index usage with EXPLAIN QUERY PLAN

**Manual Testing:**
- [ ] Create one-time event "9am Tomorrow" in Swift client
- [ ] Verify displays correct scheduled time
- [ ] Wait for execution (or mock time)
- [ ] Verify displays "Completed" after execution
- [ ] Create recurring "Every 20 minutes" schedule
- [ ] Verify displays correct next occurrence

---

## Implementation Log

### [2025-11-23 04:30] - Investigation & Planning

**Research Completed:**
- Analyzed current schema from migration 20251105201500
- Reviewed all database access patterns in storage layer
- Identified non-atomic update pattern in scheduler (line 247)
- Found transaction template in ReplaceScheduleActions
- Reviewed Go models, protobuf, and Swift client implementation

**Key Findings:**
- All timestamps stored as TEXT (RFC3339 format)
- No schedule_type column (implicit via empty/non-empty rrule)
- No next_execution column (calculated on-demand)
- UpdateLastExecution is non-transactional (race condition risk)
- Scheduler loads ALL schedules, parses RRules (inefficient)

**Design Decisions:**
- Add explicit schedule_type enum for clarity
- Store next_execution for query performance
- Implement atomic UpdateScheduleExecution transaction
- Keep TEXT timestamps (SQLite compatibility)

**Status**: Plan created, ready to implement

### [2025-11-23 15:55] - Implementation Progress

**Phase 1-3 Complete:**
- ✅ Created migration file: `20251123215210_add_schedule_refinements.sql`
- ✅ Updated Go models: Added ScheduleType enum and NextExecution field
- ✅ Updated protobuf: Added ScheduleType enum and fields, regenerated code

**Phase 4-5 Complete:**
- ✅ Added `calculateNextFromRRule()` helper function in storage layer
- ✅ Implemented `UpdateScheduleExecution()` with atomic transaction
- ✅ Updated `CreateSchedule()` to calculate and store schedule_type and next_execution
- ✅ Updated `GetSchedule()` SELECT query to include new fields

**Remaining Work:**
- [ ] Update `ListSchedulesByRoutine()` SELECT query (line 272)
- [ ] Update `GetActiveSchedules()` SELECT query (line 450+)
- [ ] Update `UpdateSchedule()` to recalculate next_execution
- [ ] Simplify `scheduler.shouldTrigger()` logic
- [ ] Update `scheduler.dispatchScheduleEvent()` to use UpdateScheduleExecution
- [ ] Complete `API.GetNextExecution()` implementation
- [ ] Update Swift client display logic
- [ ] Run migration and test

**Files Modified So Far:**
1. `backend/internal/storage/migrations/20251123215210_add_schedule_refinements.sql` - NEW
2. `backend/internal/models/models.go` - Added ScheduleType enum and NextExecution
3. `proto/vibecare.proto` - Added ScheduleType enum and fields
4. Generated proto files - Regenerated
5. `backend/internal/storage/schedule.go` - Partially updated (CreateSchedule, GetSchedule done)

---

## Dependencies & Blockers

### Dependencies
- [x] Migration system (goose) working
- [x] RRule library available (`github.com/teambition/rrule-go`)
- [x] Protobuf generation working (`just proto-gen`)
- [x] Backend server for testing

### Blockers
None

### Questions
- [x] Should we keep TEXT timestamps or convert to TIMESTAMP? → **Keep TEXT (SQLite compatibility)**
- [x] Migration strategy: single atomic or phased? → **Phased (safer)**
- [x] Update before or after event dispatch? → **Before (prevents duplicates)**

---

## Completion Checklist

Before marking as 🟢 Completed:
- [ ] Migration created and tested
- [ ] Go models updated
- [ ] Protobuf updated and regenerated
- [ ] Storage layer implements atomic updates
- [ ] Scheduler uses next_execution for queries
- [ ] API service returns next_execution
- [ ] Swift client displays correct status
- [ ] All unit tests passing
- [ ] Integration tests passing
- [ ] Performance improvement verified
- [ ] No regressions in existing functionality
- [ ] Success criteria met

---

## Archive Notes

**Completed**: TBD
**Outcome**: TBD
**Follow-up Tasks**: TBD
