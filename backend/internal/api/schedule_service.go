package api

import (
	"context"
	"strings"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
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

	// Validate the request
	if req.RoutineId == "" {
		return nil, status.Errorf(codes.InvalidArgument, "routine_id is required")
	}
	if req.Name == "" {
		return nil, status.Errorf(codes.InvalidArgument, "name is required")
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
		req.Id, // Client-provided ID (optional)
		req.RoutineId,
		req.Name,
		req.RecurrenceJson,
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
	schedule.RecurrenceJSON = req.RecurrenceJson
	schedule.DTStart = dtstart
	schedule.ExDates = req.Exdates
	schedule.Notes = req.Notes

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

// GetNextExecution calculates the next execution time for a schedule
func (s *Server) GetNextExecution(ctx context.Context, req *pb.GetNextExecutionRequest) (*pb.GetNextExecutionResponse, error) {
	s.logger.Info("Getting next execution", zap.String("schedule_id", req.ScheduleId))

	schedule, err := s.db.GetSchedule(req.ScheduleId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get schedule: %v", err)
	}
	if schedule == nil {
		return nil, status.Errorf(codes.NotFound, "schedule not found")
	}

	// TODO: Implement RRule parsing and next execution calculation
	// For now, return a placeholder response
	response := &pb.GetNextExecutionResponse{
		IsPaused: !schedule.Enabled,
	}

	// If enabled and has dtstart, calculate a simple next execution
	if schedule.Enabled && schedule.DTStart != nil {
		// Simple implementation: add 1 hour to dtstart for demo
		nextExecution := schedule.DTStart.Add(time.Hour)
		response.NextExecution = timestamppb.New(nextExecution)
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
	pbSchedule := &pb.Schedule{
		ScheduleId:     schedule.ScheduleID,
		RoutineId:      schedule.RoutineID,
		Name:           schedule.Name,
		RecurrenceJson: schedule.RecurrenceJSON,
		Exdates:        schedule.ExDates,
		Notes:          schedule.Notes,
		Enabled:        schedule.Enabled,
		CreatedAt:      timestamppb.New(schedule.CreatedAt),
		UpdatedAt:      timestamppb.New(schedule.UpdatedAt),
	}

	if schedule.DTStart != nil {
		pbSchedule.Dtstart = timestamppb.New(*schedule.DTStart)
	}

	if schedule.LastExecution != nil {
		pbSchedule.LastExecution = timestamppb.New(*schedule.LastExecution)
	}

	return pbSchedule
}