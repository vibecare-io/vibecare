# Fix RRule CPU Spike Issue

## Status: 🟢 Completed

## Problem Summary

The backend CPU spikes to 800% when:
1. Swift client's `RecurrenceBuilder` fires `onChange` handlers rapidly
2. Each change triggers `UpdateSchedule` gRPC call
3. Backend calls `calculateNextFromRRule()` which uses `rrule-go` library
4. `rrule-go.After()` iterates from DTSTART to find next occurrence - O(n) complexity
5. High-frequency rules (MINUTELY) + multiple concurrent requests = CPU exhaustion

## Root Cause

The `rrule-go` library's `After()` method iterates through **every occurrence** from DTSTART until it finds one after the target time. For `FREQ=MINUTELY` with even a 1-day-old DTSTART, that's 1,440 iterations.

---

## Backend Fixes ✅

### 1. Optimize DTSTART for High-Frequency Rules ✅

**File**: `backend/internal/storage/schedule.go`

Added `optimizeDtstartForFrequency()` helper that moves DTSTART closer to the target time for MINUTELY/HOURLY rules, reducing iterations from thousands to just a few.

### 2. Timeout Protection (2s) ✅

**File**: `backend/internal/storage/schedule.go`

Wrapped `After()` call with 2-second timeout. If calculation exceeds limit, returns error rather than blocking.

### 3. API Validation ✅

**File**: `backend/internal/api/schedule_service.go`

Added `validateRRule()` that rejects problematic patterns at API level:
- High-frequency (MINUTELY/HOURLY) + BYHOUR/BYMINUTE constraints

### 4. Telemetry Spans ✅

**File**: `backend/internal/storage/schedule.go`

Added OTEL spans with diagnostic attributes for slow calculation investigation.

### 5. Tests ✅

**File**: `backend/internal/storage/schedule_test.go`

Added comprehensive tests for RRule validation and optimization.

---

## Swift Client Fixes ✅

### 1. Hide "At times" for High-Frequency Rules ✅

**File**: `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift:128-135`

Added `supportsTimePicker` property to `RRule.Frequency` enum. Hides time picker UI for MINUTELY/HOURLY frequencies.

### 2. Debounce TextEditor (700ms) ✅

**File**: `clients/macos-swift/VibeCare/vibecare/Views/Schedules/Components/RecurrenceBuilder.swift:456`

Added 700ms debounce to advanced RRule TextEditor to prevent hammering backend.

### 3. Client-Side Validation UI ✅

**File**: `clients/macos-swift/VibeCare/vibecare/Views/Schedules/Components/RecurrenceBuilder.swift:43, 473-484, 694-719`

- Added `rruleValidationError` state
- TextEditor border turns red when validation fails
- Error message with warning icon displayed
- "Parse & Apply" button disabled when invalid
- Only fires `onRRuleChange` callback if validation passes

### 4. Strict RRule Parser ✅

**File**: `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift:205-338, 341-362`

Rewrote `RRule.fromRRuleString()` with strict validation:
- FREQ is required
- Unknown keys rejected (was silently ignored)
- BYHOUR must be 0-23
- BYMINUTE must be 0-59
- BYDAY must be valid day codes (MO-SU)
- BYMONTHDAY must be 1-31 or -31 to -1
- BYMONTH must be 1-12
- COUNT/INTERVAL must be positive integers

**Example**: `FREQ=DAILY;BYHOUR=8;BYMINUTE=0alskjdklf` now throws `Invalid BYMINUTE value: 0alskjdklf` instead of silently accepting.

### 5. Pattern Validation ✅

**File**: `clients/macos-swift/VibeCare/vibecare/Views/Schedules/Components/RecurrenceBuilder.swift:694-719`

`validateRRule()` rejects high-frequency rules with BYHOUR/BYMINUTE with clear error message.

---

## Files Modified

### Backend
1. `backend/internal/storage/schedule.go` - DTSTART optimization, timeout, telemetry
2. `backend/internal/api/schedule_service.go` - API validation
3. `backend/internal/storage/schedule_test.go` - Tests

### Swift Client
1. `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift`
   - `supportsTimePicker` property (line 128-135)
   - Strict `fromRRuleString()` parser (line 205-338)
   - New `RRuleError` cases (line 341-362)

2. `clients/macos-swift/VibeCare/vibecare/Views/Schedules/Components/RecurrenceBuilder.swift`
   - `rruleValidationError` state (line 43)
   - Debounce task state (line 42)
   - "At times" picker hidden for high-freq (line 288)
   - BYHOUR/BYMINUTE guard in `syncUIToRRule()` (line 569-573)
   - Validation UI with red border and error (line 473-484)
   - `validateRRule()` method (line 694-719)
   - 700ms debounce (line 456)

3. `clients/macos-swift/VibeCare/vibecare/ViewModels/ScheduleViewModel.swift`
   - `extractErrorMessage(from:fallback:)` helper (line 374-389)

---

## Result

✅ Backend protected with DTSTART optimization + 2s timeout + API validation
✅ Swift client prevents malformed RRules at UI level with clear error messages
✅ Users can no longer create problematic patterns through the UI
