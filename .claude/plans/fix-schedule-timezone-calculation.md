# Task: Fix Schedule Timezone Not Applied in Next Execution Calculation

**Status**: 🟢 Completed
**Created**: 2025-11-28
**Last Updated**: 2025-11-28

---

## Overview

### Goal
Fix the bug where schedules ignore the stored `schedule_timezone` when calculating `next_execution`. Currently, a schedule set for "9am CDT" triggers at "9am UTC" instead.

### Success Criteria
- [x] Schedules respect `schedule_timezone` when calculating `next_execution`
- [x] A schedule for "9am America/Chicago" triggers at 9am Central time, not 9am UTC
- [x] Existing schedules with "UTC" timezone continue to work correctly
- [x] All existing tests pass
- [x] New tests cover timezone-aware calculation

### Scope
**In Scope:**
- Fix `calculateNextFromRRule` to use timezone
- Update all callers to pass timezone parameter
- Update `UpdateScheduleExecution` signature

**Out of Scope:**
- Migration script for existing schedules (they'll self-correct on next trigger/update)
- Client-side timezone changes

---

## Research & Context

### Root Cause Discovery
Initial investigation found that removing the `Z` suffix from DTSTART wasn't sufficient. Through testing with Go code, discovered that `rrule.StrToRRule()` **always defaults to UTC** regardless of formatting - it ignores the `time.Location` from the input time.

**Solution**: After parsing, set `rule.Options.Dtstart` with the correct timezone Location, then recreate the rule using `rrule.NewRRule(rule.Options)` which properly respects the Location.

### Design Decisions
1. **Decision**: Create helper function `applyTimezoneToRRule`
   - **Reasoning**: Encapsulates the fix logic, makes it clear what's happening
   - **Implementation**: Sets correct Location on Dtstart and recreates rule

---

## Implementation Plan

### Files Modified
- [x] `backend/internal/storage/schedule.go` - Main timezone fix
- [x] `backend/internal/scheduler/scheduler.go` - Update caller
- [x] `backend/internal/storage/schedule_test.go` - Added timezone tests

### Implementation Steps
- [x] Step 1: Add `applyTimezoneToRRule` helper function (~line 31)
- [x] Step 2: Update `calculateNextFromRRule` signature to accept timezone
- [x] Step 3: Update `calculateNextFromRRuleWithContext` to load and apply timezone
- [x] Step 4: Update `optimizeDtstartForFrequency` to accept location parameter
- [x] Step 5: Update `CreateSchedule` caller to pass timezone
- [x] Step 6: Update `UpdateSchedule` caller to pass timezone
- [x] Step 7: Update `UpdateScheduleExecution` signature and implementation
- [x] Step 8: Update `scheduler.go` caller to pass timezone
- [x] Step 9: Update existing tests to use new 4-parameter signature
- [x] Step 10: Add comprehensive timezone tests

---

## Implementation Log

### `backend/internal/storage/schedule.go`

**Added helper function** `applyTimezoneToRRule` (line ~31):
```go
// applyTimezoneToRRule fixes the timezone on a parsed RRule.
// rrule.StrToRRule() always defaults to UTC - this function sets the correct
// timezone Location on DTStart and recreates the rule so it respects the timezone.
func applyTimezoneToRRule(rule *rrule.RRule, dtstartWithTimezone time.Time) (*rrule.RRule, error) {
    rule.Options.Dtstart = dtstartWithTimezone
    return rrule.NewRRule(rule.Options)
}
```

**Updated `calculateNextFromRRule`** signature:
```go
func calculateNextFromRRule(rruleStr string, dtstart, after time.Time, scheduleTimezone string) (time.Time, error)
```

**Updated `calculateNextFromRRuleWithContext`**:
- Loads timezone with `time.LoadLocation(scheduleTimezone)`
- Converts `dtstart` and `after` to the schedule's timezone
- Calls `applyTimezoneToRRule` after parsing to fix the timezone

**Updated `optimizeDtstartForFrequency`**:
- Added `loc *time.Location` parameter
- Uses provided location in `time.Date()` call

**Updated `UpdateScheduleExecution`** signature:
```go
func (db *DB) UpdateScheduleExecution(scheduleID string, scheduleType models.ScheduleType,
                                       rrule string, dtstart time.Time, scheduleTimezone string) error
```

### `backend/internal/scheduler/scheduler.go`

**Updated call at line ~152**:
```go
if err := s.db.UpdateScheduleExecution(schedule.ScheduleID, schedule.ScheduleType,
    schedule.RRule, dtstart, schedule.ScheduleTimezone); err != nil {
```

### `backend/internal/storage/schedule_test.go`

**Updated existing tests** to pass 4th parameter ("UTC") to `calculateNextFromRRule`

**Added 7 new timezone tests**:
1. `TestCalculateNextFromRRule_TimezoneRespected` - Verifies Chicago (UTC-6) correctly offsets from UTC
2. `TestCalculateNextFromRRule_InvalidTimezone` - Invalid timezone falls back to UTC
3. `TestCalculateNextFromRRule_EmptyTimezone` - Empty timezone falls back to UTC
4. `TestCalculateNextFromRRule_PositiveOffsetTimezone` - Tokyo (UTC+9) test
5. `TestCalculateNextFromRRule_DayBoundaryCrossing` - LA 23:00 crosses to next UTC day
6. `TestCalculateNextFromRRule_DSTTransition` - DST spring forward handling
7. `TestCalculateNextFromRRule_MultipleTimezones` - Tests NY, London, Berlin, Sydney, Tokyo

---

## Dependencies & Blockers

### Dependencies
- [x] `schedule_timezone` column exists in DB (migration 20251124064130)
- [x] Timezone captured from client via protobuf

### Blockers
_None_

---

## Completion Checklist

Before marking as 🟢 Completed:
- [x] All implementation steps completed
- [x] Tests written and passing (7 new timezone tests)
- [x] Implementation log fully documented
- [x] No outstanding blockers
- [x] Success criteria met

---

## Archive Notes

**Completed**: 2025-11-28
**Outcome**: Successfully fixed timezone calculation. All tests pass including 7 new edge case tests covering multiple timezones, invalid/empty timezone fallback, day boundary crossing, and DST transitions.
**Follow-up Tasks**: None - existing schedules will self-correct on next trigger or update.
