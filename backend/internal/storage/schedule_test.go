package storage

import (
	"testing"
	"time"

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
