package scheduler

import (
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	"go.uber.org/zap"
)

func TestShouldTrigger(t *testing.T) {
	now := time.Now()
	futureTime := now.Add(1 * time.Hour)
	pastTime := now.Add(-1 * time.Hour)

	tests := []struct {
		name          string
		nextExecution *time.Time
		enabled       bool
		shouldTrigger bool
	}{
		{
			name:          "next_execution is nil",
			nextExecution: nil,
			enabled:       true,
			shouldTrigger: false,
		},
		{
			name:          "next_execution in future",
			nextExecution: &futureTime,
			enabled:       true,
			shouldTrigger: false,
		},
		{
			name:          "next_execution equals now",
			nextExecution: &now,
			enabled:       true,
			shouldTrigger: true,
		},
		{
			name:          "next_execution in past",
			nextExecution: &pastTime,
			enabled:       true,
			shouldTrigger: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			schedule := &models.Schedule{
				ScheduleID:    "test-schedule",
				NextExecution: tt.nextExecution,
				Enabled:       tt.enabled,
			}

			// Create a minimal scheduler with logger
			logger := zap.NewNop()
			s := &Scheduler{
				logger: logger,
			}

			result := s.shouldTrigger(schedule, now)
			if result != tt.shouldTrigger {
				t.Errorf("shouldTrigger() = %v, want %v", result, tt.shouldTrigger)
			}
		})
	}
}

func TestGetNextExecution(t *testing.T) {
	futureTime := time.Now().Add(24 * time.Hour)

	tests := []struct {
		name          string
		schedule      *models.Schedule
		expectNil     bool
	}{
		{
			name: "disabled schedule returns nil",
			schedule: &models.Schedule{
				Enabled:       false,
				NextExecution: &futureTime,
			},
			expectNil: true,
		},
		{
			name: "enabled with next_execution returns value",
			schedule: &models.Schedule{
				Enabled:       true,
				NextExecution: &futureTime,
			},
			expectNil: false,
		},
		{
			name: "enabled without next_execution returns nil",
			schedule: &models.Schedule{
				Enabled:       true,
				NextExecution: nil,
			},
			expectNil: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &Scheduler{}
			result, err := s.GetNextExecution(tt.schedule)

			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}

			isNil := result == nil
			if isNil != tt.expectNil {
				t.Errorf("GetNextExecution() nil = %v, want %v", isNil, tt.expectNil)
			}

			if !tt.expectNil && result != nil && !result.Equal(*tt.schedule.NextExecution) {
				t.Errorf("GetNextExecution() = %v, want %v", result, tt.schedule.NextExecution)
			}
		})
	}
}

func TestScheduleTypeHandling(t *testing.T) {
	now := time.Now()
	pastTime := now.Add(-1 * time.Hour)

	tests := []struct {
		name          string
		scheduleType  models.ScheduleType
		nextExecution *time.Time
		shouldTrigger bool
	}{
		{
			name:          "ONE_SHOT with past next_execution should trigger",
			scheduleType:  models.ScheduleTypeOneShot,
			nextExecution: &pastTime,
			shouldTrigger: true,
		},
		{
			name:          "ONE_SHOT already executed (nil next_execution)",
			scheduleType:  models.ScheduleTypeOneShot,
			nextExecution: nil,
			shouldTrigger: false,
		},
		{
			name:          "RECURRING with past next_execution should trigger",
			scheduleType:  models.ScheduleTypeRecurring,
			nextExecution: &pastTime,
			shouldTrigger: true,
		},
		{
			name:          "RECURRING with nil next_execution (no more occurrences)",
			scheduleType:  models.ScheduleTypeRecurring,
			nextExecution: nil,
			shouldTrigger: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			schedule := &models.Schedule{
				ScheduleType:  tt.scheduleType,
				NextExecution: tt.nextExecution,
				Enabled:       true,
			}

			logger := zap.NewNop()
			s := &Scheduler{
				logger: logger,
			}
			result := s.shouldTrigger(schedule, now)

			if result != tt.shouldTrigger {
				t.Errorf("shouldTrigger() = %v, want %v for %s", result, tt.shouldTrigger, tt.scheduleType)
			}
		})
	}
}
