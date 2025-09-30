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

// CreateRoutine creates a new routine
func (s *Server) CreateRoutine(ctx context.Context, req *pb.CreateRoutineRequest) (*pb.CreateRoutineResponse, error) {
	// Log request details, including client-provided ID if present (for audit trail)
	if req.Id != "" {
		s.logger.Info("Creating routine with client-provided ID",
			zap.String("client_id", req.Id),
			zap.String("profile_id", req.ProfileId),
			zap.String("name", req.Name))
	} else {
		s.logger.Info("Creating routine",
			zap.String("profile_id", req.ProfileId),
			zap.String("name", req.Name))
	}

	// Validate the request at API layer
	if err := validation.ValidateUUID("id", req.Id); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid id: %v", err)
	}

	if err := validation.ValidateRequired("profile_id", req.ProfileId); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid profile_id: %v", err)
	}

	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	if err := validation.ValidateDescription(req.Description); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid description: %v", err)
	}

	if err := validation.ValidateStringArray("action_ids", req.ActionIds, validation.MaxArraySize); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid action_ids: %v", err)
	}

	if err := validation.ValidateJSONMap("metadata", req.Metadata); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid metadata: %v", err)
	}

	// Create the routine (passing client ID which may be empty)
	routine, err := s.db.CreateRoutine(
		req.Id, // Client-provided ID (optional)
		req.ProfileId,
		req.Name,
		req.Description,
		req.ActionIds,
		req.Enabled,
		req.Metadata,
	)
	if err != nil {
		s.logger.Error("Failed to create routine", zap.Error(err))
		errMsg := err.Error()

		// Check if error is due to ID collision
		if req.Id != "" && strings.Contains(errMsg, "already exists") {
			return nil, status.Errorf(codes.AlreadyExists, "routine with provided ID already exists")
		}
		// Check if error is due to invalid ID format
		if req.Id != "" && strings.Contains(errMsg, "invalid routine ID format") {
			return nil, status.Errorf(codes.InvalidArgument, "invalid routine ID format - must be valid UUID")
		}
		return nil, status.Errorf(codes.Internal, "failed to create routine: %v", err)
	}

	return &pb.CreateRoutineResponse{
		Routine: convertToProtoRoutine(routine),
	}, nil
}

// GetRoutine retrieves a routine by ID
func (s *Server) GetRoutine(ctx context.Context, req *pb.GetRoutineRequest) (*pb.GetRoutineResponse, error) {
	s.logger.Info("Getting routine", zap.String("id", req.Id))

	routine, err := s.db.GetRoutine(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	return &pb.GetRoutineResponse{
		Routine: convertToProtoRoutine(routine),
	}, nil
}

// UpdateRoutine updates a routine
func (s *Server) UpdateRoutine(ctx context.Context, req *pb.UpdateRoutineRequest) (*pb.Routine, error) {
	s.logger.Info("Updating routine", zap.String("id", req.Id))

	// Validate inputs at API layer
	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	if err := validation.ValidateDescription(req.Description); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid description: %v", err)
	}

	if err := validation.ValidateStringArray("action_ids", req.ActionIds, validation.MaxArraySize); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid action_ids: %v", err)
	}

	if err := validation.ValidateJSONMap("metadata", req.Metadata); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid metadata: %v", err)
	}

	// Get existing routine
	routine, err := s.db.GetRoutine(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	// Update fields
	routine.Name = req.Name
	routine.Description = req.Description
	routine.ActionIDs = req.ActionIds
	routine.Metadata = req.Metadata

	// Save updates
	updatedRoutine, err := s.db.UpdateRoutine(routine)
	if err != nil {
		s.logger.Error("Failed to update routine", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to update routine: %v", err)
	}

	return convertToProtoRoutine(updatedRoutine), nil
}

// DeleteRoutine deletes a routine
func (s *Server) DeleteRoutine(ctx context.Context, req *pb.DeleteRoutineRequest) (*emptypb.Empty, error) {
	s.logger.Info("Deleting routine", zap.String("id", req.Id))

	// Check if routine exists
	routine, err := s.db.GetRoutine(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	// Delete routine
	err = s.db.DeleteRoutine(req.Id)
	if err != nil {
		s.logger.Error("Failed to delete routine", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to delete routine: %v", err)
	}

	return &emptypb.Empty{}, nil
}

// ListRoutines lists routines for a profile
func (s *Server) ListRoutines(ctx context.Context, req *pb.ListRoutinesRequest) (*pb.ListRoutinesResponse, error) {
	s.logger.Info("Listing routines", zap.String("profile_id", req.ProfileId))

	routines, err := s.db.ListRoutines(req.ProfileId, req.EnabledOnly)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to list routines: %v", err)
	}

	pbRoutines := make([]*pb.Routine, 0, len(routines))
	for _, r := range routines {
		pbRoutines = append(pbRoutines, convertToProtoRoutine(r))
	}

	return &pb.ListRoutinesResponse{
		Routines:   pbRoutines,
		TotalCount: int32(len(routines)),
	}, nil
}

// EnableRoutine enables a routine
func (s *Server) EnableRoutine(ctx context.Context, req *pb.EnableRoutineRequest) (*pb.Routine, error) {
	s.logger.Info("Enabling routine", zap.String("id", req.Id))

	// Check if routine exists
	routine, err := s.db.GetRoutine(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	// Enable the routine
	err = s.db.UpdateRoutineEnabled(req.Id, true)
	if err != nil {
		s.logger.Error("Failed to enable routine", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to enable routine: %v", err)
	}

	// Return updated routine
	routine.Enabled = true
	routine.UpdatedAt = time.Now()
	return convertToProtoRoutine(routine), nil
}

// DisableRoutine disables a routine
func (s *Server) DisableRoutine(ctx context.Context, req *pb.DisableRoutineRequest) (*pb.Routine, error) {
	s.logger.Info("Disabling routine", zap.String("id", req.Id))

	// Check if routine exists
	routine, err := s.db.GetRoutine(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	// Disable the routine
	err = s.db.UpdateRoutineEnabled(req.Id, false)
	if err != nil {
		s.logger.Error("Failed to disable routine", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to disable routine: %v", err)
	}

	// Return updated routine
	routine.Enabled = false
	routine.UpdatedAt = time.Now()
	return convertToProtoRoutine(routine), nil
}

// ExecuteRoutine executes a routine and logs the result
func (s *Server) ExecuteRoutine(ctx context.Context, req *pb.ExecuteRoutineRequest) (*pb.ExecutionLog, error) {
	s.logger.Info("Executing routine",
		zap.String("routine_id", req.RoutineId),
		zap.Bool("force", req.Force))

	// Validate inputs at API layer
	if err := validation.ValidateNotes(req.Notes); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid notes: %v", err)
	}

	// Check if routine exists
	routine, err := s.db.GetRoutine(req.RoutineId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get routine: %v", err)
	}
	if routine == nil {
		return nil, status.Errorf(codes.NotFound, "routine not found")
	}

	// Check if routine is enabled (unless forced)
	if !routine.Enabled && !req.Force {
		return nil, status.Errorf(codes.FailedPrecondition, "routine is disabled")
	}

	// TODO: Execute the actual actions here
	// For now, we'll just simulate a successful execution
	actionResults := map[string]string{
		"status":  "simulated",
		"message": "Routine execution simulated successfully",
	}

	// Create execution log
	executionLog, err := s.db.CreateExecutionLog(req.RoutineId, true, req.Notes, actionResults)
	if err != nil {
		s.logger.Error("Failed to create execution log", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to create execution log: %v", err)
	}

	// Update routine's last executed time
	err = s.db.UpdateRoutineLastExecuted(req.RoutineId)
	if err != nil {
		s.logger.Warn("Failed to update routine last executed time", zap.Error(err))
	}

	return convertToProtoExecutionLog(executionLog), nil
}

// GetExecutionLogs retrieves execution logs for a routine
func (s *Server) GetExecutionLogs(ctx context.Context, req *pb.GetExecutionLogsRequest) (*pb.GetExecutionLogsResponse, error) {
	s.logger.Info("Getting execution logs",
		zap.String("routine_id", req.RoutineId),
		zap.Int32("limit", req.Limit))

	logs, err := s.db.GetExecutionLogs(req.RoutineId, int(req.Limit))
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get execution logs: %v", err)
	}

	pbLogs := make([]*pb.ExecutionLog, 0, len(logs))
	for _, log := range logs {
		pbLogs = append(pbLogs, convertToProtoExecutionLog(log))
	}

	return &pb.GetExecutionLogsResponse{
		Logs: pbLogs,
	}, nil
}

// Helper functions to convert between models and protobuf

func convertToProtoRoutine(routine *models.Routine) *pb.Routine {
	pbRoutine := &pb.Routine{
		Id:          routine.ID,
		ProfileId:   routine.ProfileID,
		Name:        routine.Name,
		Description: routine.Description,
		ActionIds:   routine.ActionIDs,
		Enabled:     routine.Enabled,
		Metadata:    routine.Metadata,
		CreatedAt:   timestamppb.New(routine.CreatedAt),
		UpdatedAt:   timestamppb.New(routine.UpdatedAt),
	}

	if routine.LastExecutedAt != nil {
		pbRoutine.LastExecutedAt = timestamppb.New(*routine.LastExecutedAt)
	}

	return pbRoutine
}

func convertToProtoExecutionLog(log *models.ExecutionLog) *pb.ExecutionLog {
	return &pb.ExecutionLog{
		LogId:         log.LogID,
		RoutineId:     log.RoutineID,
		Timestamp:     timestamppb.New(log.Timestamp),
		Completed:     log.Completed,
		Notes:         log.Notes,
		ActionResults: log.ActionResults,
	}
}
