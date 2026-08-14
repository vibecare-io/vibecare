package storage

import (
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/teambition/rrule-go"
	"github.com/vibecare-io/vibecare/backend/internal/models"
)

func TestCalculateNextFromRRule(t *testing.T) {
	dtstart := time.Date(2025, 1, 1, 9, 0, 0, 0, time.UTC)
	after := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		rrule     string
		dtstart   time.Time
		after     time.Time
		wantError bool
	}{
		{
			name:      "valid daily recurrence",
			rrule:     "FREQ=DAILY",
			dtstart:   dtstart,
			after:     after,
			wantError: false,
		},
		{
			name:      "valid weekly recurrence",
			rrule:     "FREQ=WEEKLY;BYDAY=MO,WE,FR",
			dtstart:   dtstart,
			after:     after,
			wantError: false,
		},
		{
			name:      "empty rrule returns error",
			rrule:     "",
			dtstart:   dtstart,
			after:     after,
			wantError: true,
		},
		{
			name:      "invalid rrule format",
			rrule:     "INVALID_FORMAT",
			dtstart:   dtstart,
			after:     after,
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Use UTC timezone for basic tests
			next, err := calculateNextFromRRule(tt.rrule, tt.dtstart, tt.after, "UTC")
			if tt.wantError {
				if err == nil {
					t.Errorf("expected error but got none")
				}
				return
			}
			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}
			if next.IsZero() {
				t.Errorf("expected non-zero next execution time")
			}
			if !next.After(tt.after) {
				t.Errorf("next execution %v should be after %v", next, tt.after)
			}
		})
	}
}

func TestScheduleTypeDetection(t *testing.T) {
	tests := []struct {
		name            string
		rrule           string
		expectedType    models.ScheduleType
		expectNextExec  bool
		dtstartInFuture bool
	}{
		{
			name:            "empty rrule creates ONE_SHOT",
			rrule:           "",
			expectedType:    models.ScheduleTypeOneShot,
			expectNextExec:  true,
			dtstartInFuture: true,
		},
		{
			name:            "empty rrule with past dtstart has no next_execution",
			rrule:           "",
			expectedType:    models.ScheduleTypeOneShot,
			expectNextExec:  false,
			dtstartInFuture: false,
		},
		{
			name:            "non-empty rrule creates RECURRING",
			rrule:           "FREQ=DAILY",
			expectedType:    models.ScheduleTypeRecurring,
			expectNextExec:  true,
			dtstartInFuture: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var dtstart time.Time
			if tt.dtstartInFuture {
				dtstart = time.Now().Add(24 * time.Hour)
			} else {
				dtstart = time.Now().Add(-24 * time.Hour)
			}

			var scheduleType models.ScheduleType
			if tt.rrule == "" {
				scheduleType = models.ScheduleTypeOneShot
			} else {
				scheduleType = models.ScheduleTypeRecurring
			}

			if scheduleType != tt.expectedType {
				t.Errorf("expected type %v, got %v", tt.expectedType, scheduleType)
			}

			// Test next_execution logic
			var nextExecution *time.Time
			if scheduleType == models.ScheduleTypeOneShot {
				if dtstart.After(time.Now()) {
					nextExecution = &dtstart
				}
			} else {
				next, err := calculateNextFromRRule(tt.rrule, dtstart, time.Now(), "UTC")
				if err == nil && !next.IsZero() {
					nextExecution = &next
				}
			}

			hasNextExec := nextExecution != nil
			if hasNextExec != tt.expectNextExec {
				t.Errorf("expected nextExecution presence: %v, got: %v", tt.expectNextExec, hasNextExec)
			}
		})
	}
}

func TestUpdateScheduleRecalculation(t *testing.T) {
	tests := []struct {
		name             string
		oldRRule         string
		newRRule         string
		expectTypeChange bool
		oldType          models.ScheduleType
		newType          models.ScheduleType
	}{
		{
			name:             "change from RECURRING to ONE_SHOT",
			oldRRule:         "FREQ=DAILY",
			newRRule:         "",
			expectTypeChange: true,
			oldType:          models.ScheduleTypeRecurring,
			newType:          models.ScheduleTypeOneShot,
		},
		{
			name:             "change from ONE_SHOT to RECURRING",
			oldRRule:         "",
			newRRule:         "FREQ=WEEKLY",
			expectTypeChange: true,
			oldType:          models.ScheduleTypeOneShot,
			newType:          models.ScheduleTypeRecurring,
		},
		{
			name:             "update rrule pattern within RECURRING",
			oldRRule:         "FREQ=DAILY",
			newRRule:         "FREQ=WEEKLY",
			expectTypeChange: false,
			oldType:          models.ScheduleTypeRecurring,
			newType:          models.ScheduleTypeRecurring,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate type detection logic
			oldType := models.ScheduleTypeRecurring
			if tt.oldRRule == "" {
				oldType = models.ScheduleTypeOneShot
			}

			newType := models.ScheduleTypeRecurring
			if tt.newRRule == "" {
				newType = models.ScheduleTypeOneShot
			}

			if oldType != tt.oldType {
				t.Errorf("old type: expected %v, got %v", tt.oldType, oldType)
			}

			if newType != tt.newType {
				t.Errorf("new type: expected %v, got %v", tt.newType, newType)
			}

			if (oldType != newType) != tt.expectTypeChange {
				t.Errorf("type change: expected %v, got %v", tt.expectTypeChange, oldType != newType)
			}
		})
	}
}

// ========== Timezone-Specific Tests ==========

// TestCreateScheduleWithTimezone tests schedule creation with timezone field
func TestCreateScheduleWithTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine first
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	tests := []struct {
		name             string
		scheduleTimezone string
		expectedTimezone string
	}{
		{
			name:             "Schedule with America/Los_Angeles timezone",
			scheduleTimezone: "America/Los_Angeles",
			expectedTimezone: "America/Los_Angeles",
		},
		{
			name:             "Schedule with Asia/Tokyo timezone",
			scheduleTimezone: "Asia/Tokyo",
			expectedTimezone: "Asia/Tokyo",
		},
		{
			name:             "Schedule with empty timezone defaults to UTC",
			scheduleTimezone: "",
			expectedTimezone: "UTC",
		},
		{
			name:             "Schedule with Europe/Berlin timezone",
			scheduleTimezone: "Europe/Berlin",
			expectedTimezone: "Europe/Berlin",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scheduleID := uuid.New().String()
			dtstart := time.Now().Add(24 * time.Hour)

			schedule, err := db.CreateSchedule(
				scheduleID,
				profile.ID,
				routine.ID,
				"Test Schedule",
				"FREQ=DAILY",
				tt.scheduleTimezone,
				&dtstart,
				[]string{},
				"Test notes",
				true,
			)
			if err != nil {
				t.Fatalf("CreateSchedule failed: %v", err)
			}

			if schedule.ScheduleTimezone != tt.expectedTimezone {
				t.Errorf("Expected schedule_timezone %s, got %s", tt.expectedTimezone, schedule.ScheduleTimezone)
			}

			// Verify schedule was created in database
			retrieved, err := db.GetSchedule(schedule.ScheduleID)
			if err != nil {
				t.Fatalf("GetSchedule failed: %v", err)
			}

			if retrieved.ScheduleTimezone != tt.expectedTimezone {
				t.Errorf("Retrieved schedule_timezone %s, expected %s", retrieved.ScheduleTimezone, tt.expectedTimezone)
			}
		})
	}
}

// TestUpdateScheduleTimezone tests updating schedule timezone
func TestUpdateScheduleTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create schedule with America/New_York timezone
	scheduleID := uuid.New().String()
	dtstart := time.Now().Add(24 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Test Schedule",
		"FREQ=DAILY",
		"America/New_York",
		&dtstart,
		[]string{},
		"Test notes",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	if schedule.ScheduleTimezone != "America/New_York" {
		t.Errorf("Initial schedule_timezone should be America/New_York, got %s", schedule.ScheduleTimezone)
	}

	// Update timezone to Asia/Tokyo
	schedule.ScheduleTimezone = "Asia/Tokyo"
	updated, err := db.UpdateSchedule(schedule)
	if err != nil {
		t.Fatalf("UpdateSchedule failed: %v", err)
	}

	if updated.ScheduleTimezone != "Asia/Tokyo" {
		t.Errorf("Updated schedule_timezone should be Asia/Tokyo, got %s", updated.ScheduleTimezone)
	}

	// Verify update persisted
	retrieved, err := db.GetSchedule(schedule.ScheduleID)
	if err != nil {
		t.Fatalf("GetSchedule failed: %v", err)
	}

	if retrieved.ScheduleTimezone != "Asia/Tokyo" {
		t.Errorf("Retrieved schedule_timezone should be Asia/Tokyo, got %s", retrieved.ScheduleTimezone)
	}
}

// TestCalculateNextFromRRule_TimezoneRespected verifies that next_execution is calculated
// correctly in the schedule's timezone, not UTC.
// Example: A schedule for 12:00 Chicago time should have next_execution at 18:00 UTC (CST = UTC-6)
func TestCalculateNextFromRRule_TimezoneRespected(t *testing.T) {
	// Use a fixed "now" in January (CST, UTC-6) to avoid DST complications
	// dtstart: Jan 15, 2025 at 09:00 Chicago time (15:00 UTC)
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Fatalf("Failed to load Chicago timezone: %v", err)
	}

	// Create dtstart as 09:00 Chicago time, stored as UTC
	dtstartChicago := time.Date(2025, 1, 15, 9, 0, 0, 0, chicago)
	dtstartUTC := dtstartChicago.UTC() // This is what gets stored in DB

	// "after" is Jan 15, 2025 at 10:00 Chicago time (we've passed 9:00, so next is tomorrow)
	afterChicago := time.Date(2025, 1, 15, 10, 0, 0, 0, chicago)
	afterUTC := afterChicago.UTC()

	// RRule: Daily at 09:00 and 30 minutes
	rruleStr := "FREQ=DAILY;BYHOUR=9;BYMINUTE=30"

	// Calculate next execution WITH Chicago timezone
	nextWithTZ, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "America/Chicago")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with timezone failed: %v", err)
	}

	// Calculate next execution WITH UTC (to compare)
	nextWithUTC, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "UTC")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with UTC failed: %v", err)
	}

	// Verify: next execution with Chicago timezone should be 09:30 Chicago time
	// which is 15:30 UTC (Chicago is UTC-6 in January)
	nextInChicago := nextWithTZ.In(chicago)
	if nextInChicago.Hour() != 9 || nextInChicago.Minute() != 30 {
		t.Errorf("Expected next execution at 09:30 Chicago time, got %02d:%02d",
			nextInChicago.Hour(), nextInChicago.Minute())
	}

	// The UTC hour should be 15 (9 + 6 = 15)
	if nextWithTZ.UTC().Hour() != 15 {
		t.Errorf("Expected next execution at 15:30 UTC (09:30 Chicago), got %02d:%02d UTC",
			nextWithTZ.UTC().Hour(), nextWithTZ.UTC().Minute())
	}

	// Verify that UTC timezone gives a DIFFERENT result (09:30 UTC, not 15:30 UTC)
	if nextWithUTC.UTC().Hour() != 9 {
		t.Errorf("Expected UTC calculation at 09:30 UTC, got %02d:%02d UTC",
			nextWithUTC.UTC().Hour(), nextWithUTC.UTC().Minute())
	}

	// The key assertion: Chicago and UTC results should be 6 hours apart
	diff := nextWithTZ.Sub(nextWithUTC)
	expectedDiff := 6 * time.Hour
	if diff != expectedDiff {
		t.Errorf("Expected 6 hour difference between Chicago and UTC calculations, got %v", diff)
	}

	t.Logf("✓ Chicago timezone: next at %v (09:30 Chicago = 15:30 UTC)", nextWithTZ.UTC())
	t.Logf("✓ UTC timezone: next at %v (09:30 UTC)", nextWithUTC.UTC())
	t.Logf("✓ Difference: %v (expected 6h for CST)", diff)
}

// TestCalculateNextFromRRule_InvalidTimezone verifies fallback to UTC for invalid timezone
func TestCalculateNextFromRRule_InvalidTimezone(t *testing.T) {
	dtstart := time.Date(2025, 1, 15, 9, 0, 0, 0, time.UTC)
	after := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)
	rruleStr := "FREQ=DAILY;BYHOUR=12;BYMINUTE=0"

	// Invalid timezone should fallback to UTC
	nextInvalid, err := calculateNextFromRRule(rruleStr, dtstart, after, "Invalid/Timezone")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with invalid timezone failed: %v", err)
	}

	// Should behave same as UTC
	nextUTC, err := calculateNextFromRRule(rruleStr, dtstart, after, "UTC")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with UTC failed: %v", err)
	}

	if !nextInvalid.Equal(nextUTC) {
		t.Errorf("Invalid timezone should fallback to UTC. Got %v, expected %v", nextInvalid, nextUTC)
	}

	t.Logf("✓ Invalid timezone falls back to UTC: %v", nextInvalid.UTC())
}

// TestCalculateNextFromRRule_EmptyTimezone verifies fallback to UTC for empty timezone
func TestCalculateNextFromRRule_EmptyTimezone(t *testing.T) {
	dtstart := time.Date(2025, 1, 15, 9, 0, 0, 0, time.UTC)
	after := time.Date(2025, 1, 15, 10, 0, 0, 0, time.UTC)
	rruleStr := "FREQ=DAILY;BYHOUR=12;BYMINUTE=0"

	// Empty timezone should fallback to UTC
	nextEmpty, err := calculateNextFromRRule(rruleStr, dtstart, after, "")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with empty timezone failed: %v", err)
	}

	// Should behave same as UTC
	nextUTC, err := calculateNextFromRRule(rruleStr, dtstart, after, "UTC")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with UTC failed: %v", err)
	}

	if !nextEmpty.Equal(nextUTC) {
		t.Errorf("Empty timezone should fallback to UTC. Got %v, expected %v", nextEmpty, nextUTC)
	}

	t.Logf("✓ Empty timezone falls back to UTC: %v", nextEmpty.UTC())
}

// TestCalculateNextFromRRule_PositiveOffsetTimezone tests timezone with positive UTC offset (e.g., Asia/Tokyo UTC+9)
func TestCalculateNextFromRRule_PositiveOffsetTimezone(t *testing.T) {
	tokyo, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Fatalf("Failed to load Tokyo timezone: %v", err)
	}

	// Create dtstart as 09:00 Tokyo time
	dtstartTokyo := time.Date(2025, 1, 15, 9, 0, 0, 0, tokyo)
	dtstartUTC := dtstartTokyo.UTC() // 00:00 UTC (Tokyo is UTC+9)

	// "after" is 10:00 Tokyo time
	afterTokyo := time.Date(2025, 1, 15, 10, 0, 0, 0, tokyo)
	afterUTC := afterTokyo.UTC()

	// RRule: Daily at 14:00
	rruleStr := "FREQ=DAILY;BYHOUR=14;BYMINUTE=0"

	// Calculate with Tokyo timezone
	nextWithTZ, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "Asia/Tokyo")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with Tokyo timezone failed: %v", err)
	}

	// Verify: 14:00 Tokyo = 05:00 UTC (14 - 9 = 5)
	nextInTokyo := nextWithTZ.In(tokyo)
	if nextInTokyo.Hour() != 14 || nextInTokyo.Minute() != 0 {
		t.Errorf("Expected next execution at 14:00 Tokyo time, got %02d:%02d",
			nextInTokyo.Hour(), nextInTokyo.Minute())
	}

	if nextWithTZ.UTC().Hour() != 5 {
		t.Errorf("Expected next execution at 05:00 UTC (14:00 Tokyo), got %02d:%02d UTC",
			nextWithTZ.UTC().Hour(), nextWithTZ.UTC().Minute())
	}

	t.Logf("✓ Tokyo timezone (UTC+9): 14:00 Tokyo = %v UTC", nextWithTZ.UTC())
}

// TestCalculateNextFromRRule_DayBoundaryCrossing tests schedule that crosses day boundary when converted to UTC
func TestCalculateNextFromRRule_DayBoundaryCrossing(t *testing.T) {
	// Los Angeles is UTC-8 in winter
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatalf("Failed to load LA timezone: %v", err)
	}

	// Schedule for 23:00 LA time = 07:00 UTC next day
	dtstartLA := time.Date(2025, 1, 15, 20, 0, 0, 0, la)
	dtstartUTC := dtstartLA.UTC()

	// "after" is 21:00 LA time on Jan 15
	afterLA := time.Date(2025, 1, 15, 21, 0, 0, 0, la)
	afterUTC := afterLA.UTC()

	// RRule: Daily at 23:00
	rruleStr := "FREQ=DAILY;BYHOUR=23;BYMINUTE=0"

	// Calculate with LA timezone
	nextWithTZ, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "America/Los_Angeles")
	if err != nil {
		t.Fatalf("calculateNextFromRRule with LA timezone failed: %v", err)
	}

	// Verify: 23:00 LA = 07:00 UTC next day (23 + 8 = 31 = 07:00 next day)
	nextInLA := nextWithTZ.In(la)
	if nextInLA.Hour() != 23 || nextInLA.Minute() != 0 {
		t.Errorf("Expected next execution at 23:00 LA time, got %02d:%02d",
			nextInLA.Hour(), nextInLA.Minute())
	}

	// Should be Jan 15 23:00 LA = Jan 16 07:00 UTC
	if nextWithTZ.UTC().Hour() != 7 {
		t.Errorf("Expected next execution at 07:00 UTC (23:00 LA), got %02d:%02d UTC",
			nextWithTZ.UTC().Hour(), nextWithTZ.UTC().Minute())
	}

	// The LA date should be Jan 15, but UTC date should be Jan 16
	if nextInLA.Day() != 15 {
		t.Errorf("Expected LA date to be Jan 15, got Jan %d", nextInLA.Day())
	}
	if nextWithTZ.UTC().Day() != 16 {
		t.Errorf("Expected UTC date to be Jan 16 (next day), got Jan %d", nextWithTZ.UTC().Day())
	}

	t.Logf("✓ Day boundary crossing: 23:00 LA (Jan 15) = 07:00 UTC (Jan 16)")
}

// TestCalculateNextFromRRule_DSTTransition tests schedule behavior during DST transition
// Note: This tests the "spring forward" case where 2am doesn't exist
func TestCalculateNextFromRRule_DSTTransition(t *testing.T) {
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Fatalf("Failed to load Chicago timezone: %v", err)
	}

	// DST starts March 9, 2025 at 2am in Chicago (clocks jump to 3am)
	// Schedule a task for 2:30am which doesn't exist on that day

	// dtstart before DST
	dtstartChicago := time.Date(2025, 3, 8, 2, 0, 0, 0, chicago)
	dtstartUTC := dtstartChicago.UTC()

	// "after" is March 9, 2025 at 1:00am Chicago (before the DST jump)
	afterChicago := time.Date(2025, 3, 9, 1, 0, 0, 0, chicago)
	afterUTC := afterChicago.UTC()

	// RRule: Daily at 2:30am
	rruleStr := "FREQ=DAILY;BYHOUR=2;BYMINUTE=30"

	// Calculate with Chicago timezone
	nextWithTZ, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "America/Chicago")
	if err != nil {
		t.Fatalf("calculateNextFromRRule during DST transition failed: %v", err)
	}

	// The library should handle DST - either skip to next valid time or next day
	// We just verify it doesn't crash and returns a reasonable result
	nextInChicago := nextWithTZ.In(chicago)

	t.Logf("✓ DST transition handled: next execution at %v Chicago (%v UTC)",
		nextInChicago.Format("2006-01-02 15:04:05 MST"), nextWithTZ.UTC())

	// Verify the result is after our "after" time
	if !nextWithTZ.After(afterUTC) {
		t.Errorf("Next execution should be after %v, got %v", afterUTC, nextWithTZ)
	}
}

// TestCalculateNextFromRRule_MultipleTimezones tests various timezones produce correct UTC hours
func TestCalculateNextFromRRule_MultipleTimezones(t *testing.T) {
	tests := []struct {
		name            string
		timezone        string
		expectedUTCHour int // expected UTC hour for 12:00 local time
	}{
		{"New York (EST)", "America/New_York", 17}, // 12:00 EST = 17:00 UTC
		{"London (GMT)", "Europe/London", 12},      // 12:00 GMT = 12:00 UTC
		{"Berlin (CET)", "Europe/Berlin", 11},      // 12:00 CET = 11:00 UTC
		{"Sydney (AEDT)", "Australia/Sydney", 1},   // 12:00 AEDT = 01:00 UTC
		{"Tokyo (JST)", "Asia/Tokyo", 3},           // 12:00 JST = 03:00 UTC
	}

	// Use January date to have consistent offsets (avoid DST complexity for this test)
	// Start early in the day so all timezones can find 12:00 local on the same day
	dtstart := time.Date(2025, 1, 15, 0, 0, 0, 0, time.UTC)
	after := time.Date(2025, 1, 15, 0, 30, 0, 0, time.UTC)
	rruleStr := "FREQ=DAILY;BYHOUR=12;BYMINUTE=0"

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			nextWithTZ, err := calculateNextFromRRule(rruleStr, dtstart, after, tt.timezone)
			if err != nil {
				t.Fatalf("calculateNextFromRRule with %s failed: %v", tt.timezone, err)
			}

			loc, _ := time.LoadLocation(tt.timezone)
			nextInTZ := nextWithTZ.In(loc)

			// Verify local time is 12:00
			if nextInTZ.Hour() != 12 {
				t.Errorf("Expected 12:00 local time, got %02d:00", nextInTZ.Hour())
			}

			// Verify UTC hour matches expected
			if nextWithTZ.UTC().Hour() != tt.expectedUTCHour {
				t.Errorf("Expected %02d:00 UTC for 12:00 %s, got %02d:00 UTC",
					tt.expectedUTCHour, tt.timezone, nextWithTZ.UTC().Hour())
			}

			t.Logf("✓ %s: 12:00 local = %02d:00 UTC", tt.timezone, nextWithTZ.UTC().Hour())
		})
	}
}

// TestListSchedulesWithTimezone tests listing schedules includes timezone
func TestListSchedulesWithTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create multiple schedules with different timezones
	timezones := []string{"America/Los_Angeles", "Europe/Paris", "Asia/Singapore"}
	dtstart := time.Now().Add(24 * time.Hour)

	for i, tz := range timezones {
		scheduleID := uuid.New().String()
		name := "Schedule " + string(rune('A'+i))
		_, err := db.CreateSchedule(
			scheduleID,
			profile.ID,
			routine.ID,
			name,
			"FREQ=DAILY",
			tz,
			&dtstart,
			[]string{},
			"",
			true,
		)
		if err != nil {
			t.Fatalf("CreateSchedule failed for %s: %v", name, err)
		}
	}

	// List all schedules for the routine
	schedules, err := db.ListSchedulesByRoutine(routine.ID)
	if err != nil {
		t.Fatalf("ListSchedulesByRoutine failed: %v", err)
	}

	if len(schedules) != 3 {
		t.Fatalf("Expected 3 schedules, got %d", len(schedules))
	}

	// Verify all schedules have correct timezones
	foundTimezones := make(map[string]bool)
	for _, schedule := range schedules {
		if schedule.ScheduleTimezone == "" {
			t.Errorf("Schedule %s has empty timezone", schedule.Name)
		}
		foundTimezones[schedule.ScheduleTimezone] = true
	}

	for _, tz := range timezones {
		if !foundTimezones[tz] {
			t.Errorf("Expected to find timezone %s in results", tz)
		}
	}
}

// TestScheduleTimezoneDefaultBehavior tests timezone defaults
func TestScheduleTimezoneDefaultBehavior(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	tests := []struct {
		name             string
		timezone         string
		expectedTimezone string
	}{
		{
			name:             "Empty string defaults to UTC",
			timezone:         "",
			expectedTimezone: "UTC",
		},
		{
			name:             "Explicit UTC",
			timezone:         "UTC",
			expectedTimezone: "UTC",
		},
		{
			name:             "Custom timezone preserved",
			timezone:         "America/Chicago",
			expectedTimezone: "America/Chicago",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scheduleID := uuid.New().String()
			dtstart := time.Now().Add(24 * time.Hour)

			schedule, err := db.CreateSchedule(
				scheduleID,
				profile.ID,
				routine.ID,
				"Test",
				"FREQ=DAILY",
				tt.timezone,
				&dtstart,
				[]string{},
				"",
				true,
			)
			if err != nil {
				t.Fatalf("CreateSchedule failed: %v", err)
			}

			if schedule.ScheduleTimezone != tt.expectedTimezone {
				t.Errorf("Expected timezone %s, got %s", tt.expectedTimezone, schedule.ScheduleTimezone)
			}
		})
	}
}

// TestScheduleTimezonePreservesOtherFields tests that timezone updates don't affect other fields
func TestScheduleTimezonePreservesOtherFields(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create schedule
	scheduleID := uuid.New().String()
	dtstart := time.Now().Add(24 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Test Schedule",
		"FREQ=WEEKLY;BYDAY=MO,WE,FR",
		"UTC",
		&dtstart,
		[]string{"2025-01-15"},
		"Important meeting",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	originalCreatedAt := schedule.CreatedAt
	originalRRule := schedule.RRule
	originalExDates := schedule.ExDates

	time.Sleep(10 * time.Millisecond) // Ensure timestamps differ

	// Update only timezone
	schedule.ScheduleTimezone = "America/New_York"
	updated, err := db.UpdateSchedule(schedule)
	if err != nil {
		t.Fatalf("UpdateSchedule failed: %v", err)
	}

	// Verify timezone changed
	if updated.ScheduleTimezone != "America/New_York" {
		t.Errorf("Timezone should be America/New_York, got %s", updated.ScheduleTimezone)
	}

	// Verify other fields preserved
	if updated.RRule != originalRRule {
		t.Errorf("RRule should be preserved, got %s", updated.RRule)
	}
	if len(updated.ExDates) != len(originalExDates) {
		t.Errorf("ExDates should be preserved, got %v", updated.ExDates)
	}
	if updated.Notes != "Important meeting" {
		t.Errorf("Notes should be preserved, got %s", updated.Notes)
	}

	// CreatedAt should not change
	if !updated.CreatedAt.Equal(originalCreatedAt) {
		t.Errorf("CreatedAt should not change on update")
	}

	// UpdatedAt should change
	if !updated.UpdatedAt.After(originalCreatedAt) {
		t.Errorf("UpdatedAt should be after CreatedAt")
	}
}

// TestScheduleTimezoneWithRecurringSchedules tests timezone handling for recurring schedules
func TestScheduleTimezoneWithRecurringSchedules(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create recurring schedule with specific timezone
	scheduleID := uuid.New().String()
	dtstart := time.Now().Add(24 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Daily Standup",
		"FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
		"America/Los_Angeles",
		&dtstart,
		[]string{},
		"Team meeting",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	if schedule.ScheduleType != models.ScheduleTypeRecurring {
		t.Errorf("Schedule should be RECURRING, got %s", schedule.ScheduleType)
	}

	if schedule.ScheduleTimezone != "America/Los_Angeles" {
		t.Errorf("Schedule timezone should be America/Los_Angeles, got %s", schedule.ScheduleTimezone)
	}

	// Verify next_execution was calculated
	if schedule.NextExecution == nil {
		t.Error("NextExecution should be calculated for recurring schedule")
	}
}

// TestScheduleTimezoneWithOneTimeEvents tests timezone handling for one-time events
func TestScheduleTimezoneWithOneTimeEvents(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create one-time event with specific timezone
	scheduleID := uuid.New().String()
	dtstart := time.Now().Add(48 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Project Deadline",
		"", // Empty rrule = one-time event
		"Europe/London",
		&dtstart,
		[]string{},
		"Final submission",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	if schedule.ScheduleType != models.ScheduleTypeOneShot {
		t.Errorf("Schedule should be ONE_SHOT, got %s", schedule.ScheduleType)
	}

	if schedule.ScheduleTimezone != "Europe/London" {
		t.Errorf("Schedule timezone should be Europe/London, got %s", schedule.ScheduleTimezone)
	}

	// For one-time events in the future, next_execution should be dtstart
	if schedule.NextExecution == nil {
		t.Error("NextExecution should be set for future one-time event")
	} else if !schedule.NextExecution.Equal(dtstart) {
		t.Errorf("NextExecution should equal dtstart for one-time event")
	}
}

// ========== RRule Performance Fix Tests ==========

// TestIsProblematicRRule tests detection of RRule patterns that cause CPU spikes.
// High-frequency rules (SECONDLY, MINUTELY, HOURLY) combined with BYHOUR/BYMINUTE
// constraints force the rrule library to iterate through many non-matching occurrences.
func TestIsProblematicRRule(t *testing.T) {
	tests := []struct {
		name        string
		freq        rrule.Frequency
		byhour      []int
		byminute    []int
		problematic bool
	}{
		// SECONDLY frequency cases
		{
			name:        "SECONDLY with BYHOUR is problematic",
			freq:        rrule.SECONDLY,
			byhour:      []int{9},
			byminute:    nil,
			problematic: true,
		},
		{
			name:        "SECONDLY with BYMINUTE is problematic",
			freq:        rrule.SECONDLY,
			byhour:      nil,
			byminute:    []int{30},
			problematic: true,
		},
		{
			name:        "SECONDLY with both BYHOUR and BYMINUTE is problematic",
			freq:        rrule.SECONDLY,
			byhour:      []int{9},
			byminute:    []int{30},
			problematic: true,
		},
		{
			name:        "SECONDLY without constraints is safe",
			freq:        rrule.SECONDLY,
			byhour:      nil,
			byminute:    nil,
			problematic: false,
		},
		// MINUTELY frequency cases
		{
			name:        "MINUTELY with BYHOUR is problematic",
			freq:        rrule.MINUTELY,
			byhour:      []int{9},
			byminute:    nil,
			problematic: true,
		},
		{
			name:        "MINUTELY with multiple BYHOUR is problematic",
			freq:        rrule.MINUTELY,
			byhour:      []int{9, 12, 18},
			byminute:    nil,
			problematic: true,
		},
		{
			name:        "MINUTELY with only BYMINUTE is safe",
			freq:        rrule.MINUTELY,
			byhour:      nil,
			byminute:    []int{0, 30},
			problematic: false,
		},
		{
			name:        "MINUTELY without constraints is safe",
			freq:        rrule.MINUTELY,
			byhour:      nil,
			byminute:    nil,
			problematic: false,
		},
		// HOURLY frequency cases
		{
			name:        "HOURLY with BYHOUR is problematic",
			freq:        rrule.HOURLY,
			byhour:      []int{9},
			byminute:    nil,
			problematic: true,
		},
		{
			name:        "HOURLY with BYMINUTE is safe",
			freq:        rrule.HOURLY,
			byhour:      nil,
			byminute:    []int{0},
			problematic: false,
		},
		{
			name:        "HOURLY without constraints is safe",
			freq:        rrule.HOURLY,
			byhour:      nil,
			byminute:    nil,
			problematic: false,
		},
		// Lower frequency rules - always safe
		{
			name:        "DAILY with BYHOUR is safe",
			freq:        rrule.DAILY,
			byhour:      []int{9},
			byminute:    []int{0},
			problematic: false,
		},
		{
			name:        "WEEKLY with BYHOUR is safe",
			freq:        rrule.WEEKLY,
			byhour:      []int{9},
			byminute:    []int{0},
			problematic: false,
		},
		{
			name:        "MONTHLY with BYHOUR is safe",
			freq:        rrule.MONTHLY,
			byhour:      []int{9},
			byminute:    nil,
			problematic: false,
		},
		{
			name:        "YEARLY with BYHOUR is safe",
			freq:        rrule.YEARLY,
			byhour:      []int{0},
			byminute:    []int{0},
			problematic: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opts := rrule.ROption{
				Freq:     tt.freq,
				Byhour:   tt.byhour,
				Byminute: tt.byminute,
			}
			result := isProblematicRRule(tt.freq, opts)
			if result != tt.problematic {
				t.Errorf("isProblematicRRule(freq=%v, byhour=%v, byminute=%v) = %v, want %v",
					tt.freq, tt.byhour, tt.byminute, result, tt.problematic)
			}
		})
	}
}

// TestOptimizeDtstartForFrequency tests that dtstart is moved closer to 'after'
// for high-frequency rules to reduce iteration count.
func TestOptimizeDtstartForFrequency(t *testing.T) {
	// Fixed reference times for predictable testing
	now := time.Date(2025, 6, 15, 14, 30, 0, 0, time.UTC)
	oldDtstart := time.Date(2020, 1, 1, 9, 0, 0, 0, time.UTC) // 5+ years ago

	tests := []struct {
		name                string
		freq                rrule.Frequency
		dtstart             time.Time
		after               time.Time
		expectOptimized     bool
		expectTimePreserved bool // time-of-day should be preserved
	}{
		{
			name:                "SECONDLY moves dtstart close to after",
			freq:                rrule.SECONDLY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "MINUTELY moves dtstart close to after",
			freq:                rrule.MINUTELY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "HOURLY moves dtstart close to after",
			freq:                rrule.HOURLY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "DAILY moves dtstart close to after",
			freq:                rrule.DAILY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "WEEKLY moves dtstart close to after",
			freq:                rrule.WEEKLY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "MONTHLY moves dtstart close to after",
			freq:                rrule.MONTHLY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:                "YEARLY moves dtstart close to after",
			freq:                rrule.YEARLY,
			dtstart:             oldDtstart,
			after:               now,
			expectOptimized:     true,
			expectTimePreserved: true,
		},
		{
			name:            "dtstart after 'after' is not changed",
			freq:            rrule.MINUTELY,
			dtstart:         now.Add(1 * time.Hour), // dtstart is in the future
			after:           now,
			expectOptimized: false,
		},
		{
			name:            "recent dtstart is not changed (within lookback)",
			freq:            rrule.MINUTELY,
			dtstart:         now.Add(-30 * time.Minute), // only 30 min ago, lookback is 1 hour
			after:           now,
			expectOptimized: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := optimizeDtstartForFrequency(tt.freq, tt.dtstart, tt.after, time.UTC)

			if tt.expectOptimized {
				// Result should be different from original
				if result.Equal(tt.dtstart) {
					t.Errorf("expected dtstart to be optimized, but got original: %v", result)
				}
				// Result should be after original dtstart
				if !result.After(tt.dtstart) {
					t.Errorf("optimized dtstart %v should be after original %v", result, tt.dtstart)
				}
				// Result should be closer to 'after' than original
				originalDiff := tt.after.Sub(tt.dtstart)
				optimizedDiff := tt.after.Sub(result)
				if optimizedDiff >= originalDiff {
					t.Errorf("optimized dtstart should be closer to 'after': original diff=%v, optimized diff=%v",
						originalDiff, optimizedDiff)
				}
			} else {
				// Result should equal original
				if !result.Equal(tt.dtstart) {
					t.Errorf("expected dtstart unchanged, got %v (original: %v)", result, tt.dtstart)
				}
			}

			// Check time-of-day preservation
			if tt.expectTimePreserved && tt.expectOptimized {
				if result.Hour() != tt.dtstart.Hour() ||
					result.Minute() != tt.dtstart.Minute() ||
					result.Second() != tt.dtstart.Second() {
					t.Errorf("time-of-day not preserved: original %02d:%02d:%02d, result %02d:%02d:%02d",
						tt.dtstart.Hour(), tt.dtstart.Minute(), tt.dtstart.Second(),
						result.Hour(), result.Minute(), result.Second())
				}
			}
		})
	}
}

// TestFreqToString tests the frequency to string conversion for telemetry.
func TestFreqToString(t *testing.T) {
	tests := []struct {
		freq     rrule.Frequency
		expected string
	}{
		{rrule.YEARLY, "YEARLY"},
		{rrule.MONTHLY, "MONTHLY"},
		{rrule.WEEKLY, "WEEKLY"},
		{rrule.DAILY, "DAILY"},
		{rrule.HOURLY, "HOURLY"},
		{rrule.MINUTELY, "MINUTELY"},
		{rrule.SECONDLY, "SECONDLY"},
		{rrule.Frequency(99), "UNKNOWN(99)"},
	}

	for _, tt := range tests {
		t.Run(tt.expected, func(t *testing.T) {
			result := freqToString(tt.freq)
			if result != tt.expected {
				t.Errorf("freqToString(%v) = %q, want %q", tt.freq, result, tt.expected)
			}
		})
	}
}

// TestCalculateNextFromRRule_ProblematicPattern tests that problematic RRules
// return dtstart as fallback instead of timing out.
func TestCalculateNextFromRRule_ProblematicPattern(t *testing.T) {
	dtstart := time.Date(2025, 1, 1, 9, 0, 0, 0, time.UTC)
	after := time.Date(2025, 6, 15, 14, 0, 0, 0, time.UTC)

	// This pattern would normally cause massive iteration:
	// MINUTELY with BYHOUR constraint forces skipping 59 minutes per hour
	problematicRRule := "FREQ=MINUTELY;BYHOUR=9;BYMINUTE=0"

	result, err := calculateNextFromRRule(problematicRRule, dtstart, after, "UTC")

	// Should succeed (not timeout) and return dtstart as fallback
	if err != nil {
		t.Fatalf("expected no error for problematic rrule (should fallback to dtstart), got: %v", err)
	}

	// Result should be dtstart (the fallback behavior)
	if !result.Equal(dtstart) {
		t.Errorf("expected fallback to dtstart %v, got %v", dtstart, result)
	}
}

// TestCalculateNextFromRRule_SafePattern tests that safe high-frequency patterns work correctly.
func TestCalculateNextFromRRule_SafePattern(t *testing.T) {
	dtstart := time.Date(2025, 1, 1, 9, 0, 0, 0, time.UTC)
	after := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)

	// MINUTELY without BYHOUR constraint is safe
	safeRRule := "FREQ=MINUTELY;INTERVAL=20"

	result, err := calculateNextFromRRule(safeRRule, dtstart, after, "UTC")

	if err != nil {
		t.Fatalf("unexpected error for safe rrule: %v", err)
	}

	// Result should be after 'after'
	if !result.After(after) {
		t.Errorf("next execution %v should be after %v", result, after)
	}
}

// TestCalculateNextFromRRule_MinutelyWithTimezone tests that MINUTELY schedules
// with non-UTC timezones calculate correct next_execution times.
// This catches the bug where the Z suffix in DTSTART caused timezone misinterpretation.
func TestCalculateNextFromRRule_MinutelyWithTimezone(t *testing.T) {
	chicago, err := time.LoadLocation("America/Chicago")
	if err != nil {
		t.Fatalf("Failed to load Chicago timezone: %v", err)
	}

	// dtstart: 9:00 AM Chicago time on Jan 15, 2025
	dtstartChicago := time.Date(2025, 1, 15, 9, 0, 0, 0, chicago)
	dtstartUTC := dtstartChicago.UTC() // This is stored in DB as UTC

	// "after": 9:30 AM Chicago time - we want next execution after this
	afterChicago := time.Date(2025, 1, 15, 9, 30, 0, 0, chicago)
	afterUTC := afterChicago.UTC()

	// MINUTELY;INTERVAL=20 - should trigger every 20 minutes
	rruleStr := "FREQ=MINUTELY;INTERVAL=20"

	// Calculate next execution with Chicago timezone
	next, err := calculateNextFromRRule(rruleStr, dtstartUTC, afterUTC, "America/Chicago")
	if err != nil {
		t.Fatalf("calculateNextFromRRule failed: %v", err)
	}

	// Expected: 9:40 AM Chicago time (20 min after 9:20, which is the occurrence before 9:30)
	// From dtstart 9:00: 9:00 -> 9:20 -> 9:40 -> 10:00 ...
	// After 9:30, next should be 9:40
	expectedChicago := time.Date(2025, 1, 15, 9, 40, 0, 0, chicago)
	expectedUTC := expectedChicago.UTC()

	// Allow small tolerance for any sub-second differences
	diff := next.Sub(expectedUTC)
	if diff < -time.Second || diff > time.Second {
		t.Errorf("Expected next execution at %v (9:40 Chicago), got %v (diff: %v)",
			expectedUTC.Format(time.RFC3339), next.Format(time.RFC3339), diff)
	}

	// Critical check: next should be within reasonable range of 'after'
	// With 20-minute interval, next should be at most ~20 minutes after 'after'
	maxExpectedDiff := 20 * time.Minute
	actualDiff := next.Sub(afterUTC)
	if actualDiff > maxExpectedDiff {
		t.Errorf("TIMEZONE BUG: next_execution is %v after 'after' time, expected at most %v. "+
			"This indicates the Z suffix bug in DTSTART formatting.",
			actualDiff, maxExpectedDiff)
	}

	t.Logf("✓ MINUTELY;INTERVAL=20 with Chicago timezone: after=%v next=%v (diff=%v)",
		afterUTC.Format(time.RFC3339), next.Format(time.RFC3339), actualDiff)
}

// TestUpdateSchedule_RRuleChangeUpdatesDtstartAndNextExecution tests that changing the RRule
// updates dtstart to now and calculates next_execution based on the new dtstart.
// This gives intuitive UX: "30 min interval" = next execution in 30 min from now.
func TestUpdateSchedule_RRuleChangeRecalculatesFromNow(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create schedule with FREQ=MINUTELY;INTERVAL=20, started an hour ago
	scheduleID := uuid.New().String()
	originalDtstart := time.Now().Add(-1 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Test Schedule",
		"FREQ=MINUTELY;INTERVAL=20",
		"UTC",
		&originalDtstart,
		nil,
		"",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	// Simulate that the schedule ran 5 minutes ago
	fiveMinutesAgo := time.Now().Add(-5 * time.Minute)
	schedule.LastExecution = &fiveMinutesAgo

	// Record time before update
	beforeUpdate := time.Now()

	// Update the schedule with a new RRule (INTERVAL=10 instead of 20)
	schedule.RRule = "FREQ=MINUTELY;INTERVAL=10"
	updated, err := db.UpdateSchedule(schedule)
	if err != nil {
		t.Fatalf("UpdateSchedule failed: %v", err)
	}

	// Verify dtstart was updated to ~now (within 1 second tolerance)
	if updated.DTStart == nil {
		t.Fatal("DTStart should not be nil")
	}
	dtstartDiff := updated.DTStart.Sub(beforeUpdate)
	if dtstartDiff < 0 || dtstartDiff > 2*time.Second {
		t.Errorf("DTStart should be updated to ~now when RRule changes. Original: %v, Updated: %v, Expected: ~%v",
			originalDtstart.Format(time.RFC3339), updated.DTStart.Format(time.RFC3339), beforeUpdate.Format(time.RFC3339))
	}

	// Verify next_execution is ~10 minutes from the new dtstart
	if updated.NextExecution == nil {
		t.Fatal("NextExecution should not be nil")
	}

	timeUntilNext := updated.NextExecution.Sub(time.Now())

	// Should be around 10 minutes (the new interval)
	if timeUntilNext < 9*time.Minute || timeUntilNext > 11*time.Minute {
		t.Errorf("RRule change should set next_execution to interval from now. Expected ~10 min, got %v", timeUntilNext)
	}

	t.Logf("✓ RRule change updates dtstart to now and next_execution in %v", timeUntilNext)
}

// TestUpdateSchedule_NonRRuleChangePreservesDtstartAndCadence tests that changing other fields
// (like name) preserves the existing dtstart and cadence.
func TestUpdateSchedule_NonRRuleChangePreservesCadence(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create test profile and routine
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test profile: %v", err)
	}

	routine, err := db.CreateRoutine("", profile.ID, "Test Routine", "Test Description", true, map[string]string{})
	if err != nil {
		t.Fatalf("Failed to create test routine: %v", err)
	}

	// Create schedule with FREQ=MINUTELY;INTERVAL=20, started an hour ago
	scheduleID := uuid.New().String()
	originalDtstart := time.Now().Add(-1 * time.Hour)
	schedule, err := db.CreateSchedule(
		scheduleID,
		profile.ID,
		routine.ID,
		"Test Schedule",
		"FREQ=MINUTELY;INTERVAL=20",
		"UTC",
		&originalDtstart,
		nil,
		"",
		true,
	)
	if err != nil {
		t.Fatalf("CreateSchedule failed: %v", err)
	}

	// Simulate that the schedule ran 5 minutes ago
	fiveMinutesAgo := time.Now().Add(-5 * time.Minute)
	schedule.LastExecution = &fiveMinutesAgo

	// Change the name without changing RRule
	schedule.Name = "Renamed Schedule"
	updated, err := db.UpdateSchedule(schedule)
	if err != nil {
		t.Fatalf("UpdateSchedule failed: %v", err)
	}

	// Verify dtstart was NOT changed (should still be the original)
	if updated.DTStart == nil {
		t.Fatal("DTStart should not be nil")
	}
	dtstartDiff := updated.DTStart.Sub(originalDtstart)
	if dtstartDiff < -time.Second || dtstartDiff > time.Second {
		t.Errorf("DTStart should be preserved when RRule doesn't change. Original: %v, Updated: %v",
			originalDtstart.Format(time.RFC3339), updated.DTStart.Format(time.RFC3339))
	}

	// The next_execution should be ~15 minutes from now (20 min interval - 5 min since last)
	// because we preserved the cadence
	if updated.NextExecution == nil {
		t.Fatal("NextExecution should not be nil")
	}

	timeUntilNext := updated.NextExecution.Sub(time.Now())

	// Should be around 15 minutes (20 - 5 = 15, with tolerance)
	// If it were recalculated from now with new dtstart, it would be ~20 minutes
	if timeUntilNext > 17*time.Minute {
		t.Errorf("Non-RRule change should preserve cadence. Expected next_execution ~15 min from now, got %v",
			timeUntilNext)
	}

	t.Logf("✓ Non-RRule change preserves cadence: next_execution in %v", timeUntilNext)
}
