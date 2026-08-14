package api

import (
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
)

func TestConvertToProtoSchedule(t *testing.T) {
	now := time.Now()
	dtstart := now.Add(-1 * time.Hour)
	lastExec := now.Add(-30 * time.Minute)
	nextExec := now.Add(30 * time.Minute)

	tests := []struct {
		name           string
		schedule       *models.Schedule
		expectedType   pb.ScheduleType
		expectNextExec bool
	}{
		{
			name: "ONE_SHOT type converts correctly",
			schedule: &models.Schedule{
				ScheduleID:    "test-1",
				ProfileID:     "profile-1",
				RoutineID:     "routine-1",
				ScheduleType:  models.ScheduleTypeOneShot,
				Name:          "Test Schedule",
				RRule:         "",
				Enabled:       true,
				CreatedAt:     now,
				UpdatedAt:     now,
				DTStart:       &dtstart,
				NextExecution: &nextExec,
			},
			expectedType:   pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT,
			expectNextExec: true,
		},
		{
			name: "RECURRING type converts correctly",
			schedule: &models.Schedule{
				ScheduleID:    "test-2",
				ProfileID:     "profile-1",
				RoutineID:     "routine-1",
				ScheduleType:  models.ScheduleTypeRecurring,
				Name:          "Recurring Schedule",
				RRule:         "FREQ=DAILY",
				Enabled:       true,
				CreatedAt:     now,
				UpdatedAt:     now,
				DTStart:       &dtstart,
				LastExecution: &lastExec,
				NextExecution: &nextExec,
			},
			expectedType:   pb.ScheduleType_SCHEDULE_TYPE_RECURRING,
			expectNextExec: true,
		},
		{
			name: "schedule without next_execution",
			schedule: &models.Schedule{
				ScheduleID:    "test-3",
				ProfileID:     "profile-1",
				RoutineID:     "routine-1",
				ScheduleType:  models.ScheduleTypeOneShot,
				Name:          "Completed Schedule",
				RRule:         "",
				Enabled:       true,
				CreatedAt:     now,
				UpdatedAt:     now,
				DTStart:       &dtstart,
				LastExecution: &lastExec,
				NextExecution: nil,
			},
			expectedType:   pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT,
			expectNextExec: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pbSchedule := convertToProtoSchedule(tt.schedule)

			// Check schedule_type conversion
			if pbSchedule.ScheduleType != tt.expectedType {
				t.Errorf("schedule_type = %v, want %v", pbSchedule.ScheduleType, tt.expectedType)
			}

			// Check basic fields
			if pbSchedule.ScheduleId != tt.schedule.ScheduleID {
				t.Errorf("schedule_id = %v, want %v", pbSchedule.ScheduleId, tt.schedule.ScheduleID)
			}

			if pbSchedule.Rrule != tt.schedule.RRule {
				t.Errorf("rrule = %v, want %v", pbSchedule.Rrule, tt.schedule.RRule)
			}

			// Check next_execution
			hasNextExec := pbSchedule.NextExecution != nil
			if hasNextExec != tt.expectNextExec {
				t.Errorf("next_execution presence = %v, want %v", hasNextExec, tt.expectNextExec)
			}

			if tt.expectNextExec && pbSchedule.NextExecution != nil {
				// Verify timestamp conversion is correct
				convertedTime := pbSchedule.NextExecution.AsTime()
				if !convertedTime.Equal(*tt.schedule.NextExecution) {
					t.Errorf("next_execution time = %v, want %v", convertedTime, *tt.schedule.NextExecution)
				}
			}

			// Check dtstart if present
			if tt.schedule.DTStart != nil {
				if pbSchedule.Dtstart == nil {
					t.Errorf("dtstart is nil, expected non-nil")
				} else {
					convertedDtstart := pbSchedule.Dtstart.AsTime()
					if !convertedDtstart.Equal(*tt.schedule.DTStart) {
						t.Errorf("dtstart = %v, want %v", convertedDtstart, *tt.schedule.DTStart)
					}
				}
			}

			// Check last_execution if present
			if tt.schedule.LastExecution != nil {
				if pbSchedule.LastExecution == nil {
					t.Errorf("last_execution is nil, expected non-nil")
				} else {
					convertedLastExec := pbSchedule.LastExecution.AsTime()
					if !convertedLastExec.Equal(*tt.schedule.LastExecution) {
						t.Errorf("last_execution = %v, want %v", convertedLastExec, *tt.schedule.LastExecution)
					}
				}
			}
		})
	}
}

func TestScheduleTypeEnumMapping(t *testing.T) {
	tests := []struct {
		name              string
		modelType         models.ScheduleType
		expectedProtoType pb.ScheduleType
	}{
		{
			name:              "ONE_SHOT maps correctly",
			modelType:         models.ScheduleTypeOneShot,
			expectedProtoType: pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT,
		},
		{
			name:              "RECURRING maps correctly",
			modelType:         models.ScheduleTypeRecurring,
			expectedProtoType: pb.ScheduleType_SCHEDULE_TYPE_RECURRING,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			schedule := &models.Schedule{
				ScheduleID:   "test",
				ProfileID:    "profile",
				RoutineID:    "routine",
				ScheduleType: tt.modelType,
				Name:         "Test",
				Enabled:      true,
				CreatedAt:    time.Now(),
				UpdatedAt:    time.Now(),
			}

			pbSchedule := convertToProtoSchedule(schedule)

			if pbSchedule.ScheduleType != tt.expectedProtoType {
				t.Errorf("protobuf type = %v, want %v", pbSchedule.ScheduleType, tt.expectedProtoType)
			}
		})
	}
}
