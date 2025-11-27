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
			next, err := calculateNextFromRRule(tt.rrule, tt.dtstart, tt.after)
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
		name             string
		rrule            string
		expectedType     models.ScheduleType
		expectNextExec   bool
		dtstartInFuture  bool
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
				next, err := calculateNextFromRRule(tt.rrule, dtstart, time.Now())
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
		name           string
		oldRRule       string
		newRRule       string
		expectTypeChange bool
		oldType        models.ScheduleType
		newType        models.ScheduleType
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
		name                 string
		freq                 rrule.Frequency
		dtstart              time.Time
		after                time.Time
		expectOptimized      bool
		expectTimePreserved  bool // time-of-day should be preserved
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
			result := optimizeDtstartForFrequency(tt.freq, tt.dtstart, tt.after)

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

	result, err := calculateNextFromRRule(problematicRRule, dtstart, after)

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

	result, err := calculateNextFromRRule(safeRRule, dtstart, after)

	if err != nil {
		t.Fatalf("unexpected error for safe rrule: %v", err)
	}

	// Result should be after 'after'
	if !result.After(after) {
		t.Errorf("next execution %v should be after %v", result, after)
	}
}
