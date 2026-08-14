package api

import (
	"context"
	"strings"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/validation"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// CreateSchedule creates a new schedule
func (s *Server) CreateSchedule(ctx context.Context, req *pb.CreateScheduleRequest) (*pb.Schedule, error) {
	// Log request details, including client-provided ID if present (for audit trail)
	if req.Id != "" {
		s.logger.Info("Creating schedule with client-provided ID",
			zap.String("client_id", req.Id),
			zap.String("routine_id", req.RoutineId),
			zap.String("name", req.Name))
	} else {
		s.logger.Info("Creating schedule",
			zap.String("routine_id", req.RoutineId),
			zap.String("name", req.Name))
	}

	// Validate the request at API layer
	if err := validation.ValidateUUID("id", req.Id); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid id: %v", err)
	}

	if err := validation.ValidateRequired("profile_id", req.ProfileId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid profile_id: %v", err)
	}

	if err := validation.ValidateRequired("routine_id", req.RoutineId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid routine_id: %v", err)
	}

	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	// Validate RRule (empty string allowed for one-time events)
	if err := validation.ValidateRRule(req.Rrule); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid rrule: %v", err)
	}

	if err := validation.ValidateStringArray("exdates", req.Exdates, validation.MaxArraySize); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid exdates: %v", err)
	}

	if err := validation.ValidateNotes(req.Notes); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid notes: %v", err)
	}

	// Parse dtstart if provided
	var dtstart *time.Time
	if req.Dtstart != "" {
		parsed, err := time.Parse(time.RFC3339, req.Dtstart)
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "invalid dtstart format - must be RFC3339")
		}
		dtstart = &parsed
	}

	// Create the schedule (passing client ID which may be empty)
	schedule, err := s.db.CreateSchedule(
		req.Id,        // Client-provided ID (optional)
		req.ProfileId, // Profile ID for direct access
		req.RoutineId,
		req.Name,
		req.Rrule,
		req.ScheduleTimezone, // IANA timezone for RRule calculations
		dtstart,
		req.Exdates,
		req.Notes,
		req.Enabled,
	)
	if err != nil {
		s.logger.Error("Failed to create schedule", zap.Error(err))
		errMsg := err.Error()

		// Check if error is due to ID collision
		if req.Id != "" && strings.Contains(errMsg, "already exists") {
			return nil, status.Errorf(codes.AlreadyExists, "schedule with provided ID already exists")
		}
		// Check if error is due to invalid ID format
		if req.Id != "" && strings.Contains(errMsg, "invalid schedule ID format") {
			return nil, status.Errorf(codes.InvalidArgument, "invalid schedule ID format - must be valid UUID")
		}
		// Check if error is due to routine not existing (FK constraint)
		if strings.Contains(errMsg, "does not exist") {
			return nil, status.Errorf(codes.NotFound, "routine not found")
		}
		return nil, status.Errorf(codes.Internal, "failed to create schedule: %v", err)
	}

	return convertToProtoSchedule(schedule), nil
}

// GetSchedule retrieves a schedule by ID
func (s *Server) GetSchedule(ctx context.Context, req *pb.GetScheduleRequest) (*pb.Schedule, error) {
	s.logger.Info("Getting schedule", zap.String("schedule_id", req.ScheduleId))

	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	return convertToProtoSchedule(schedule), nil
}

// UpdateSchedule updates a schedule
func (s *Server) UpdateSchedule(ctx context.Context, req *pb.UpdateScheduleRequest) (*pb.Schedule, error) {
	s.logger.Info("Updating schedule", zap.String("schedule_id", req.ScheduleId))

	// Validate inputs at API layer
	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	// Validate RRule (empty string allowed for one-time events)
	if err := validation.ValidateRRule(req.Rrule); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid rrule: %v", err)
	}

	if err := validation.ValidateStringArray("exdates", req.Exdates, validation.MaxArraySize); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid exdates: %v", err)
	}

	if err := validation.ValidateNotes(req.Notes); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid notes: %v", err)
	}

	// Get existing schedule
	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	// Parse dtstart if provided
	var dtstart *time.Time
	if req.Dtstart != "" {
		parsed, err := time.Parse(time.RFC3339, req.Dtstart)
		if err != nil {
			return nil, status.Errorf(codes.InvalidArgument, "invalid dtstart format - must be RFC3339")
		}
		dtstart = &parsed
	}

	// Update fields
	schedule.Name = req.Name
	schedule.RRule = req.Rrule
	if req.ScheduleTimezone != "" {
		schedule.ScheduleTimezone = req.ScheduleTimezone
	}
	schedule.DTStart = dtstart
	schedule.ExDates = req.Exdates
	schedule.Notes = req.Notes
	schedule.Enabled = req.Enabled
	if req.RoutineId != "" {
		schedule.RoutineID = req.RoutineId
	}

	// Save updates
	updatedSchedule, err := s.db.UpdateSchedule(schedule)
	if err != nil {
		s.logger.Error("Failed to update schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to update schedule: %v", err)
	}

	return convertToProtoSchedule(updatedSchedule), nil
}

// DeleteSchedule deletes a schedule
func (s *Server) DeleteSchedule(ctx context.Context, req *pb.DeleteScheduleRequest) (*emptypb.Empty, error) {
	s.logger.Info("Deleting schedule", zap.String("schedule_id", req.ScheduleId))

	// Check if schedule exists
	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	// Delete schedule
	err = s.db.DeleteSchedule(req.ScheduleId)
	if err != nil {
		s.logger.Error("Failed to delete schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to delete schedule: %v", err)
	}

	return &emptypb.Empty{}, nil
}

// ListSchedules lists schedules for a routine
func (s *Server) ListSchedules(ctx context.Context, req *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
	s.logger.Info("Listing schedules", zap.String("routine_id", req.RoutineId))

	schedules, err := s.db.ListSchedulesByRoutine(req.RoutineId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to list schedules: %v", err)
	}

	// Filter by enabled status if requested
	if req.EnabledOnly {
		var enabledSchedules []*models.Schedule
		for _, schedule := range schedules {
			if schedule.Enabled {
				enabledSchedules = append(enabledSchedules, schedule)
			}
		}
		schedules = enabledSchedules
	}

	pbSchedules := make([]*pb.Schedule, 0, len(schedules))
	for _, schedule := range schedules {
		pbSchedules = append(pbSchedules, convertToProtoSchedule(schedule))
	}

	return &pb.ListSchedulesResponse{
		Schedules: pbSchedules,
	}, nil
}

// GetNextExecution returns the pre-calculated next execution time for a schedule
func (s *Server) GetNextExecution(ctx context.Context, req *pb.GetNextExecutionRequest) (*pb.GetNextExecutionResponse, error) {
	s.logger.Info("Getting next execution", zap.String("schedule_id", req.ScheduleId))

	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	response := &pb.GetNextExecutionResponse{
		IsPaused: !schedule.Enabled,
	}

	// Return the pre-calculated next_execution from the database
	if schedule.NextExecution != nil {
		response.NextExecution = timestamppb.New(*schedule.NextExecution)
	}

	return response, nil
}

// PauseSchedule pauses a schedule
func (s *Server) PauseSchedule(ctx context.Context, req *pb.PauseScheduleRequest) (*pb.Schedule, error) {
	s.logger.Info("Pausing schedule", zap.String("schedule_id", req.ScheduleId))

	// Check if schedule exists
	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	// Disable the schedule
	err = s.db.EnableSchedule(req.ScheduleId, false)
	if err != nil {
		s.logger.Error("Failed to pause schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to pause schedule: %v", err)
	}

	// Return updated schedule
	schedule.Enabled = false
	schedule.UpdatedAt = time.Now()
	return convertToProtoSchedule(schedule), nil
}

// ResumeSchedule resumes a schedule
func (s *Server) ResumeSchedule(ctx context.Context, req *pb.ResumeScheduleRequest) (*pb.Schedule, error) {
	s.logger.Info("Resuming schedule", zap.String("schedule_id", req.ScheduleId))

	// Check if schedule exists
	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	// Enable the schedule
	err = s.db.EnableSchedule(req.ScheduleId, true)
	if err != nil {
		s.logger.Error("Failed to resume schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to resume schedule: %v", err)
	}

	// Return updated schedule
	schedule.Enabled = true
	schedule.UpdatedAt = time.Now()
	return convertToProtoSchedule(schedule), nil
}

// PauseAllSchedules pauses all schedules for a profile
func (s *Server) PauseAllSchedules(ctx context.Context, req *pb.PauseAllSchedulesRequest) (*emptypb.Empty, error) {
	s.logger.Info("Pausing all schedules for profile", zap.String("profile_id", req.ProfileId))

	// TODO: Implement bulk pause functionality
	// For now, return success as a placeholder
	return &emptypb.Empty{}, nil
}

// ResumeAllSchedules resumes all schedules for a profile
func (s *Server) ResumeAllSchedules(ctx context.Context, req *pb.ResumeAllSchedulesRequest) (*emptypb.Empty, error) {
	s.logger.Info("Resuming all schedules for profile", zap.String("profile_id", req.ProfileId))

	// TODO: Implement bulk resume functionality
	// For now, return success as a placeholder
	return &emptypb.Empty{}, nil
}

// Helper function to convert between models and protobuf
func convertToProtoSchedule(schedule *models.Schedule) *pb.Schedule {
	// Convert schedule_type enum to protobuf enum
	var scheduleType pb.ScheduleType
	switch schedule.ScheduleType {
	case models.ScheduleTypeOneShot:
		scheduleType = pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT
	case models.ScheduleTypeRecurring:
		scheduleType = pb.ScheduleType_SCHEDULE_TYPE_RECURRING
	default:
		scheduleType = pb.ScheduleType_SCHEDULE_TYPE_UNSPECIFIED
	}

	pbSchedule := &pb.Schedule{
		ScheduleId:       schedule.ScheduleID,
		ProfileId:        schedule.ProfileID,
		RoutineId:        schedule.RoutineID,
		ScheduleType:     scheduleType,
		Name:             schedule.Name,
		Rrule:            schedule.RRule,
		ScheduleTimezone: schedule.ScheduleTimezone,
		Exdates:          schedule.ExDates,
		Notes:            schedule.Notes,
		Enabled:          schedule.Enabled,
		CreatedAt:        timestamppb.New(schedule.CreatedAt),
		UpdatedAt:        timestamppb.New(schedule.UpdatedAt),
	}

	if schedule.DTStart != nil {
		pbSchedule.Dtstart = timestamppb.New(*schedule.DTStart)
	}

	if schedule.LastExecution != nil {
		pbSchedule.LastExecution = timestamppb.New(*schedule.LastExecution)
	}

	if schedule.NextExecution != nil {
		pbSchedule.NextExecution = timestamppb.New(*schedule.NextExecution)
	}

	return pbSchedule
}

// GetScheduleActions retrieves all action IDs for a schedule
func (s *Server) GetScheduleActions(ctx context.Context, req *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error) {
	s.logger.Info("Getting actions for schedule", zap.String("schedule_id", req.ScheduleId))

	if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
	}

	actions, err := s.db.GetScheduleActions(req.ScheduleId)
	if err != nil {
		s.logger.Error("Failed to get schedule actions", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to retrieve schedule actions")
	}

	actionIDs := make([]string, len(actions))
	for i, action := range actions {
		actionIDs[i] = action.ID
	}

	return &pb.GetScheduleActionsResponse{
		ActionIds: actionIDs,
	}, nil
}

// AddActionToSchedule adds an action to a schedule
func (s *Server) AddActionToSchedule(ctx context.Context, req *pb.AddActionToScheduleRequest) (*emptypb.Empty, error) {
	s.logger.Info("Adding action to schedule",
		zap.String("schedule_id", req.ScheduleId),
		zap.String("action_id", req.ActionId),
		zap.Int32("order", req.ActionOrder))

	if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
	}

	if err := validation.ValidateRequired("action_id", req.ActionId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid action_id: %v", err)
	}

	err := s.db.AddActionToSchedule(req.ScheduleId, req.ActionId, int(req.ActionOrder))
	if err != nil {
		s.logger.Error("Failed to add action to schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to add action to schedule")
	}

	return &emptypb.Empty{}, nil
}

// RemoveActionFromSchedule removes an action from a schedule
func (s *Server) RemoveActionFromSchedule(ctx context.Context, req *pb.RemoveActionFromScheduleRequest) (*emptypb.Empty, error) {
	s.logger.Info("Removing action from schedule",
		zap.String("schedule_id", req.ScheduleId),
		zap.String("action_id", req.ActionId))

	if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
	}

	if err := validation.ValidateRequired("action_id", req.ActionId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid action_id: %v", err)
	}

	err := s.db.RemoveActionFromSchedule(req.ScheduleId, req.ActionId)
	if err != nil {
		s.logger.Error("Failed to remove action from schedule", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to remove action from schedule")
	}

	return &emptypb.Empty{}, nil
}

// UpdateScheduleActionOrder updates the order of an action within a schedule
func (s *Server) UpdateScheduleActionOrder(ctx context.Context, req *pb.UpdateScheduleActionOrderRequest) (*emptypb.Empty, error) {
	s.logger.Info("Updating action order in schedule",
		zap.String("schedule_id", req.ScheduleId),
		zap.String("action_id", req.ActionId),
		zap.Int32("new_order", req.NewOrder))

	if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
	}

	if err := validation.ValidateRequired("action_id", req.ActionId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid action_id: %v", err)
	}

	err := s.db.UpdateScheduleActionOrder(req.ScheduleId, req.ActionId, int(req.NewOrder))
	if err != nil {
		s.logger.Error("Failed to update action order", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to update action order")
	}

	return &emptypb.Empty{}, nil
}

// ReplaceScheduleActions replaces all actions for a schedule with a new ordered list
func (s *Server) ReplaceScheduleActions(ctx context.Context, req *pb.ReplaceScheduleActionsRequest) (*emptypb.Empty, error) {
	s.logger.Info("Replacing schedule actions",
		zap.String("schedule_id", req.ScheduleId),
		zap.Int("action_count", len(req.ActionIds)))

	if err := validation.ValidateRequired("schedule_id", req.ScheduleId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid schedule_id: %v", err)
	}

	err := s.db.ReplaceScheduleActions(req.ScheduleId, req.ActionIds)
	if err != nil {
		s.logger.Error("Failed to replace schedule actions", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to replace schedule actions")
	}

	return &emptypb.Empty{}, nil
}
