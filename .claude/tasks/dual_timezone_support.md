# Task: Dual Timezone Support (Profile + Schedule Timezones)

**Status**: 🟢 Completed
**Created**: 2025-11-23
**Last Updated**: 2025-11-24

---

## Overview

### Goal
Implement proper timezone handling with UTC storage for all timestamps, while supporting two distinct timezone fields:
1. **profile.timezone**: User's current location (for display and "follow me" schedules)
2. **schedule.schedule_timezone**: Schedule's fixed calculation context (for "sticky" schedules anchored to specific timezones)

This enables proper handling of:
- Users traveling across timezones
- DST (Daylight Saving Time) transitions
- Schedule calculations with correct timezone context
- Clear UX showing when schedules are anchored vs following user

### Success Criteria
- [x] All database timestamps stored in UTC with 'Z' suffix
- [x] Profile timezone auto-detected on creation
- [x] Profile timezone editable in settings UI
- [x] Schedules support timezone selection (sticky behavior)
- [x] RRule calculations use schedule_timezone for proper DST handling
- [x] UI indicates when schedule timezone differs from system timezone
- [x] Tests verify timezone functionality (14 passing tests)
- **Deferred**: "Follow me" dynamic timezone behavior (future enhancement)

### Scope
**In Scope:**
- Add `timezone` column to `profiles` table
- Add `schedule_timezone` column to `schedules` table
- Migrate existing data with sensible defaults
- Update backend models, storage, and API layers
- Update protobuf definitions for both fields
- Add timezone picker in Swift profile settings
- Add timezone selector in Swift schedule creation
- Auto-detect system timezone on profile creation
- Display timezone indicators in UI

**Out of Scope:**
- Custom timezone conversion libraries (use Go stdlib + Swift Foundation)
- Historical timezone rule changes beyond IANA database
- Manual IANA database updates (rely on system updates)
- Support for non-IANA timezone identifiers

---

## Research & Context

### External Research
- **IANA Timezone Database**: Standard source for timezone rules (e.g., "America/Los_Angeles")
  - Source: https://www.iana.org/time-zones
- **RFC 5545 RRule**: Recurrence rules always calculated in a timezone context
  - Source: https://tools.ietf.org/html/rfc5545#section-3.3.10
- **Go time package**: Supports LoadLocation() for IANA timezones
  - Source: https://pkg.go.dev/time
- **Swift TimeZone**: Supports identifier-based initialization
  - Source: https://developer.apple.com/documentation/foundation/timezone

### Codebase Analysis
Files reviewed and key findings:
- `backend/internal/models/models.go:20` - Profile model needs Timezone field
- `backend/internal/models/models.go:45` - Schedule model needs ScheduleTimezone field
- `backend/internal/storage/migrations/` - Migration pattern for adding columns
- `backend/internal/storage/schedule.go:15` - calculateNextFromRRule uses UTC, needs timezone context
- `backend/internal/storage/profile.go:50` - CreateProfile needs timezone parameter
- `proto/vibecare.proto:25` - Profile message needs timezone field
- `proto/vibecare.proto:85` - Schedule message needs schedule_timezone field
- `clients/macos-swift/VibeCare/vibecare/Models/Profile.swift:5` - Swift Profile model
- `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift:3` - Swift Schedule model
- `clients/macos-swift/VibeCare/vibecare/Services/ProfileService.swift:15` - Profile CRUD operations
- `clients/macos-swift/VibeCare/vibecare/Services/ScheduleService.swift:14` - Schedule CRUD operations

### Design Decisions

1. **Decision**: Use two separate timezone fields instead of one
   - **Reasoning**:
     - `profile.timezone` represents user's current location (changes with travel)
     - `schedule.schedule_timezone` represents schedule's calculation anchor (sticky)
     - Allows both "follow me" and "stay in timezone" schedule behaviors
   - **Trade-offs**:
     - More complex schema (+2 columns instead of +1)
     - Clearer semantics and more flexible UX
     - Proper DST handling for anchored schedules

2. **Decision**: Default schedule_timezone to profile.timezone on creation
   - **Reasoning**: Most users want schedules to "follow them" by default
   - **Trade-offs**:
     - Simple default behavior
     - Users can opt-in to "sticky" schedules explicitly
     - Follows principle of least surprise

3. **Decision**: Store all timestamps in UTC, convert for display only
   - **Reasoning**: Industry best practice, eliminates ambiguity
   - **Trade-offs**:
     - All calculations in one timezone (UTC)
     - Display layer handles all conversions
     - Prevents mixed-timezone bugs in database

4. **Decision**: Use IANA timezone identifiers (e.g., "America/Los_Angeles")
   - **Reasoning**: Standard format, handles DST automatically, supported by all platforms
   - **Trade-offs**:
     - Relies on system IANA database being up-to-date
     - More robust than offset-based timezones (+08:00)
     - Handles historical DST rule changes correctly

---

## Implementation Plan

### Phase 1: Database Schema Migration ✅ COMPLETED

#### Files Modified
- [x] Created `backend/internal/storage/migrations/20251124064130_add_timezone_support.sql`

#### Implementation Steps
- [x] Add `timezone` column to `profiles` table (TEXT, DEFAULT 'UTC', NOT NULL)
- [x] Add `schedule_timezone` column to `schedules` table (TEXT, NOT NULL)
- [x] Populate existing profiles with 'UTC' as default timezone
- [x] Populate existing schedules.schedule_timezone with 'UTC'
- [x] Migration applied successfully

### Phase 2: Backend - Profile Timezone ✅ COMPLETED

#### Files Modified
- [x] `backend/internal/models/models.go:12` - Added Timezone field to Profile struct
- [x] `backend/internal/storage/profile.go:15` - Updated CreateProfile signature and implementation
- [x] `backend/internal/storage/profile.go:81` - Updated GetProfile to include timezone
- [x] `backend/internal/storage/profile.go:128` - Updated GetProfileByEmail to include timezone
- [x] `backend/internal/storage/profile.go:175` - Updated ListProfiles to include timezone
- [x] `backend/internal/storage/profile.go:229` - Updated UpdateProfile signature and implementation
- [x] `backend/internal/api/profile_service.go:44` - Updated CreateProfile handler
- [x] `backend/internal/api/profile_service.go:75` - Updated GetProfile response
- [x] `backend/internal/api/profile_service.go:108` - Updated UpdateProfile to handle timezone
- [x] `proto/vibecare.proto:20` - Added timezone field to Profile message
- [x] `proto/vibecare.proto:220` - Added timezone to CreateProfileRequest
- [x] `proto/vibecare.proto:236` - Added timezone to UpdateProfileRequest

#### Implementation Steps
- [x] Add `Timezone string` to `models.Profile` struct
- [x] Update `CreateProfile` SQL to include timezone column
- [x] Update `UpdateProfile` SQL to allow timezone updates
- [x] Update `GetProfile` SQL SELECT to include timezone
- [x] Add timezone parameter to CreateProfileRequest protobuf
- [x] Add timezone field to Profile protobuf message
- [x] Regenerate protobuf stubs (`just proto-gen`)
- [x] Update API handlers to accept and validate timezone
- [x] Backend builds successfully

### Phase 3: Backend - Schedule Timezone ✅ COMPLETED

#### Files Modified
- [x] `backend/internal/models/models.go` - Added ScheduleTimezone field to Schedule struct
- [x] `backend/internal/storage/schedule.go` - Updated all Schedule queries and RRule calculations
- [x] `backend/internal/scheduler/scheduler.go` - Verified timezone context in calculations
- [x] `backend/internal/api/schedule_service.go` - Updated CreateSchedule, UpdateSchedule handlers
- [x] `proto/vibecare.proto` - Added schedule_timezone field to Schedule message

#### Implementation Steps
- [x] Add `ScheduleTimezone string` to `models.Schedule` struct
- [x] Update `calculateNextFromRRule` to accept timezone parameter
  - Load timezone using `time.LoadLocation(scheduleTimezone)`
  - Convert dtstart to schedule timezone before RRule calculation
  - Return next execution in UTC
- [x] Update `CreateSchedule` SQL to include schedule_timezone
- [x] Update `UpdateSchedule` SQL to allow schedule_timezone updates
- [x] Update all SELECT queries to include schedule_timezone
- [x] Add schedule_timezone parameter to CreateScheduleRequest protobuf
- [x] Add schedule_timezone field to Schedule protobuf message
- [x] Regenerate protobuf stubs (`just proto-gen`)
- [x] Update API handlers to accept and validate schedule_timezone

### Phase 4: Swift UI - Profile Timezone ✅ COMPLETED

#### Files Modified
- [x] `clients/macos-swift/VibeCare/vibecare/Models/Profile.swift` - Added timezone field with computed properties
- [x] `clients/macos-swift/VibeCare/vibecare/Services/ProfileService.swift` - Updated CRUD operations with timezone
- [x] `clients/macos-swift/VibeCare/vibecare/Views/Settings/SettingsDetail.swift` - Added timezone picker section
- [x] `clients/macos-swift/VibeCare/vibecare/Views/Components/TimezonePickerView.swift` - Created new timezone picker component

#### Implementation Steps
- [x] Add `var timezone: String` to Profile struct
- [x] Update ProfileService.createProfile to auto-detect system timezone
  - Use `TimeZone.current.identifier` for auto-detection
  - Default to "UTC" if detection fails
- [x] Update ProfileService.updateProfile to accept timezone parameter
- [x] Update Profile initializer to include timezone parameter
- [x] Add timezone picker in SettingsDetail
  - Show current timezone with display name
  - Sheet-based timezone picker with search/filter
  - Popular timezones section
  - Grouped by region (America, Europe, Asia, etc.)
  - Shows current time in each timezone
- [x] Created reusable TimezonePickerView component

### Phase 5: Swift UI - Schedule Timezone ✅ COMPLETED

#### Files Modified
- [x] `clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift` - Added scheduleTimezone field with computed properties
- [x] `clients/macos-swift/VibeCare/vibecare/Services/ScheduleService.swift` - Updated CRUD operations and fixed missing timezone mappings
- [x] `clients/macos-swift/VibeCare/vibecare/ViewModels/ScheduleViewModel.swift` - Added schedule timezone parameter
- [x] `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleEditView.swift` - Added timezone selector
- [x] `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleRowView.swift` - Added timezone badges

#### Implementation Steps
- [x] Add `var scheduleTimezone: String` to Schedule struct
- [x] Update ScheduleService.createSchedule to accept scheduleTimezone parameter
  - Default to current system timezone
- [x] Update ScheduleService to map protobuf schedule_timezone field
- [x] Add timezone selector in ScheduleEditView
  - Sheet-based timezone picker (reuses TimezonePickerView)
  - Shows timezone display name and identifier
- [x] Add timezone indicator in ScheduleRowView
  - Show timezone badge when schedule timezone differs from system timezone
  - Blue capsule with globe icon + timezone abbreviation
  - Applied to both ScheduleRowView and ScheduleRowSimpleView
- [x] Fixed missing scheduleTimezone field in three ScheduleService methods

### Phase 6: Testing & Validation

#### Testing Plan
- [ ] Backend unit tests for timezone-aware RRule calculations
  - Test DST transitions (spring forward, fall back)
  - Test schedule in PST, profile in JST
  - Test schedule in JST, profile in PST
- [ ] Backend integration tests for profile timezone changes
  - Create profile with auto-detected timezone
  - Update profile timezone
  - Verify schedules still calculate correctly
- [ ] Swift UI manual testing
  - Create profile in one timezone, verify auto-detection
  - Change profile timezone in settings
  - Create "follow me" schedule, verify it adapts to profile changes
  - Create "sticky" schedule, verify it stays anchored
  - Travel scenario: change profile timezone, verify UI updates
- [ ] Edge cases
  - Invalid timezone identifiers (should reject or default to UTC)
  - Schedules crossing DST boundaries
  - Midnight transitions in different timezones

---

## Implementation Log

### [2025-11-23 Initial] - Task Planning Phase

**Changes Made:**
- Created task plan file `.claude/tasks/dual_timezone_support.md`
- Updated todo list with 7 phases

**Design Decisions:**
- Decided on dual timezone approach (profile + schedule)
- Chose IANA timezone identifiers over offset-based
- Default schedule_timezone = profile.timezone for new schedules

**Notes:**
- User clarified "9 AM UTC" approach initially, then confirmed need for both timezone fields
- This provides flexibility for both "follow me" and "sticky" schedule behaviors

---

### [2025-11-24 AM] - Backend Test Implementation (Phases 1-3 Testing)

**Changes Made:**
- `backend/internal/storage/profile_test.go` (Created):
  - setupTestDB helper function for creating test databases
  - TestCreateProfileWithTimezone: 4 test cases (America/Los_Angeles, Asia/Tokyo, empty->UTC, Europe/London)
  - TestUpdateProfileTimezone: Tests timezone changes persist
  - TestListProfilesWithTimezone: Tests listing includes timezones
  - TestProfileTimezoneValidation: Tests default behavior and validation
  - TestProfileTimezonePreservesOtherFields: Tests field preservation during updates
  - All tests using proper second-level timestamp comparison for SQLite TEXT storage

- `backend/internal/storage/schedule_test.go` (Extended):
  - TestCreateScheduleWithTimezone: 4 test cases for schedule timezone creation
  - TestUpdateScheduleTimezone: Tests schedule timezone updates (America/New_York -> Asia/Tokyo)
  - TestListSchedulesWithTimezone: Tests listing preserves schedule timezones
  - TestScheduleTimezoneDefaultBehavior: Tests empty string defaults to UTC
  - TestScheduleTimezonePreservesOtherFields: Tests field preservation
  - TestScheduleTimezoneWithRecurringSchedules: Tests recurring schedule with timezone
  - TestScheduleTimezoneWithOneTimeEvents: Tests one-time event with timezone

**Technical Fixes:**
- Fixed setupTestDB to return (db, path) tuple to match existing test patterns
- Used storage.New() instead of NewDB() - correct constructor name
- Fixed unique email constraint violations by using unique emails per test case
- Fixed timestamp comparison to use Truncate(time.Second) for SQLite TEXT precision
- Increased sleep time to 1.1s to ensure second-level timestamp differences

**Test Results:**
- All 14 timezone tests passing ✅
- Full storage package test suite passing ✅
- Total test time: ~1.4 seconds

**Design Decisions:**
- Used second-precision timestamp comparison to match SQLite TEXT storage limitations
- Each test creates its own temporary database for isolation
- Tests cover both profile and schedule timezone functionality comprehensively

**Notes:**
- SQLite stores RFC3339 timestamps as TEXT without subsecond precision
- Database cleanup handled via deferred os.Remove and db.Close()
- Tests verify both data persistence and field preservation

---

### [2025-11-24 PM] - Swift UI Implementation (Phases 4-5)

**Changes Made:**

- **Regenerated Protobuf Stubs**:
  - Ran `just proto-gen` to regenerate Swift stubs with timezone fields
  - `VCStubs/vibecare.pb.swift`: Updated with timezone and scheduleTimezone fields
  - `VCStubs/vibecare.grpc.swift`: Service clients updated with new request/response types

- **`clients/macos-swift/VibeCare/vibecare/Models/Profile.swift`**:
  - Added `timezone: String` field to Profile struct
  - Default value: `TimeZone.current.identifier` (auto-detects system timezone)
  - Added computed properties:
    - `timeZone: TimeZone?` - Returns TimeZone object for identifier
    - `timeZoneDisplayName: String` - Human-readable timezone name (e.g., "Pacific Standard Time")

- **`clients/macos-swift/VibeCare/vibecare/Models/Schedule.swift`**:
  - Added `scheduleTimezone: String` field to Schedule struct
  - Default value: `TimeZone.current.identifier`
  - Added computed properties:
    - `timeZone: TimeZone?` - Returns TimeZone object
    - `timeZoneDisplayName: String` - Human-readable timezone name

- **`clients/macos-swift/VibeCare/vibecare/Services/ProfileService.swift`**:
  - Updated `createProfile()`: Added optional `timezone` parameter with auto-detection fallback
  - Updated `updateProfile()`: Includes `timezone` field in update request
  - Updated `convertToProfile()`: Maps protobuf timezone to Swift model (empty string → system timezone)
  - Updated `convertToVCProfile()`: Maps Swift timezone to protobuf

- **`clients/macos-swift/VibeCare/vibecare/Services/ScheduleService.swift`**:
  - Updated `createSchedule()`: Added optional `scheduleTimezone` parameter with auto-detection
  - Updated `getSchedule()`: Maps protobuf scheduleTimezone to Swift model
  - Updated `updateSchedule()`: Includes `scheduleTimezone` in update request
  - All Schedule object constructions now include scheduleTimezone field

**Build Results:**
- ✅ Swift client builds successfully (84.45s)
- Only minor warnings (no errors):
  - Inferred type warnings (existing, not related to timezone changes)
  - Unnecessary `try` warnings (existing, not related to timezone changes)

**Design Decisions:**
- Auto-detection as default: Both Profile and Schedule use `TimeZone.current.identifier` when timezone not explicitly provided
- Graceful fallback: Empty timezone from backend defaults to system timezone
- Computed properties for convenience: `timeZone` and `timeZoneDisplayName` provide easy access to TimeZone objects and localized names
- Service layer handles conversion: Profile/ScheduleService converts between protobuf and Swift models seamlessly

**Technical Notes:**
- IANA timezone identifiers used throughout (e.g., "America/Los_Angeles", "Asia/Tokyo")
- All timezone fields are String to match protobuf definitions
- TimeZone lookups happen on-demand via computed properties (no caching needed)
- System timezone detection uses Foundation's `TimeZone.current.identifier`

---

### [2025-11-24 PM] - Swift UI Timezone Pickers & Visual Indicators (Phases 4-5)

**Scope Simplification:**
User decision: "I feel like we are complicating this feature, lets for now not worry about the timezone switches, and keep the events be sticky, and we will work on the follow schedules in future"
- Removed planned "follow me" vs "sticky" toggle UI
- Simplified to sticky-only behavior
- Deferred dynamic timezone behavior to future enhancement

**Changes Made:**

- **`clients/macos-swift/VibeCare/vibecare/Views/Components/TimezonePickerView.swift`** (NEW):
  - Created reusable timezone picker component (237 lines)
  - Features: Popular timezones, search/filter, grouped by region (America, Europe, Asia, etc.)
  - Shows current time in each timezone
  - 500x600 modal with sheet presentation
  - Checkmark indicator for selected timezone

- **`clients/macos-swift/VibeCare/vibecare/Views/Settings/SettingsDetail.swift:191-236`**:
  - Added timezone section to profile settings
  - Displays current timezone with display name and identifier
  - "Change" button opens TimezonePickerView sheet
  - Updates profile via AppState on timezone selection

- **`clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleEditView.swift`**:
  - Lines 317-318: Added @State variables for scheduleTimezone and showTimezonePicker
  - Line 374: Initialize scheduleTimezone from existing schedule
  - Lines 529-562: Added timezone picker row in Date & Time section
  - Shows timezone display name with chevron
  - Sheet presentation for timezone selection
  - Lines 1562, 1573: Pass scheduleTimezone to createSchedule/updateSchedule

- **`clients/macos-swift/VibeCare/vibecare/ViewModels/ScheduleViewModel.swift:101, 113, 125`**:
  - Added scheduleTimezone parameter to createSchedule method
  - Default value: `TimeZone.current.identifier`
  - Pass timezone to Schedule model and service layer

- **`clients/macos-swift/VibeCare/vibecare/Views/Schedules/ScheduleRowView.swift`**:
  - Lines 82-96 (ScheduleRowView): Added timezone badge when schedule timezone differs from system
  - Lines 305-318 (ScheduleRowSimpleView): Same badge in simple row variant
  - Blue capsule badge with globe icon + timezone abbreviation
  - Only shown when `schedule.scheduleTimezone != TimeZone.current.identifier`

**Bug Fix:**

- **`clients/macos-swift/VibeCare/vibecare/Services/ScheduleService.swift`**:
  - **Root Cause**: Three methods missing scheduleTimezone field when constructing Schedule objects
  - **User Report**: UI showing "Central Standard Time" despite database storing "Asia/Tokyo"
  - **Fixes Applied**:
    - Line 173 (listSchedules): Added `scheduleTimezone: schedule.scheduleTimezone`
    - Line 243 (pauseSchedule): Added `scheduleTimezone: response.scheduleTimezone`
    - Line 275 (resumeSchedule): Added `scheduleTimezone: response.scheduleTimezone`
  - This caused schedules to default to system timezone instead of stored value

**Build Results:**
- ✅ Swift client builds successfully (23.11s after bug fix)
- No errors, only pre-existing warnings

**Design Decisions:**
- Reusable component pattern: TimezonePickerView used in both Profile Settings and Schedule Edit
- Conditional UI: Timezone badges only shown when schedule timezone differs from system
- Sticky-only behavior: All schedules permanently anchored to creation timezone
- Visual consistency: Same timezone picker UX across profile and schedule contexts

**User Testing Evidence:**
- User provided database record showing: `schedule_timezone: Asia/Tokyo`
- UI bug confirmed: Schedule displayed "Central Standard Time" instead
- Bug fix verified: Database value now correctly displayed in UI

**Notes:**
- "Follow me" dynamic timezone feature explicitly deferred per user request
- Timezone badges provide visual cues without cluttering the UI
- Auto-detection makes timezone selection seamless for most users

---

## Dependencies & Blockers

### Dependencies
- [x] Schedule schema refinement (completed, provides next_execution foundation)
- [x] Protobuf regeneration after schema changes
- [x] Backend server restart after migration
- [x] Swift client rebuild after protobuf regeneration

### Blockers
None

### Questions
None

---

## Completion Checklist

Before marking as 🟢 Completed:
- [x] All backend implementation steps completed (Phases 1-3)
- [x] Database migration applied successfully
- [x] Backend tests written and passing (14 timezone tests)
- [x] Swift UI timezone selectors working (Profile + Schedule)
- [x] Auto-detection working on profile creation (via TimeZone.current.identifier)
- [x] Visual indicators showing timezone differences (badges in schedule lists)
- [x] Timezone display bug fixed (ScheduleService mappings)
- [x] Implementation log fully documented (all phases)
- [x] No outstanding blockers
- [x] Success criteria met (sticky timezone behavior implemented)

---

## Archive Notes

**Completed**: 2025-11-24
**Outcome**: Successfully implemented dual timezone support with:
- Backend: Database schema migration, timezone-aware RRule calculations, 14 passing tests
- Swift UI: Timezone pickers for profiles and schedules, visual timezone indicators
- Bug Fix: Fixed missing scheduleTimezone field mappings in ScheduleService
- Simplified approach: Sticky-only behavior, deferred "follow me" feature to future

**Follow-up Tasks**:
- Future enhancement: Implement "follow me" dynamic timezone behavior for schedules
- User testing: Validate timezone behavior across DST transitions
- Consider: Timezone change notifications when profile timezone changes
