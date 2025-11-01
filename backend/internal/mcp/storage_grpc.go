package mcp

import (
	"context"
	"fmt"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// GRPCStorageAdapter implements Storage interface using gRPC client
type GRPCStorageAdapter struct {
	conn          *grpc.ClientConn
	routineClient pb.RoutineServiceClient
	scheduleClient pb.ScheduleServiceClient
	actionClient  pb.ActionServiceClient
	profileID     string
}

// NewGRPCStorageAdapter creates a new adapter for gRPC-based storage access
func NewGRPCStorageAdapter(serverAddr string, profileID string) (Storage, error) {
	// Connect to the gRPC server
	conn, err := grpc.NewClient(serverAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("failed to connect to gRPC server: %w", err)
	}

	return &GRPCStorageAdapter{
		conn:          conn,
		routineClient: pb.NewRoutineServiceClient(conn),
		scheduleClient: pb.NewScheduleServiceClient(conn),
		actionClient:  pb.NewActionServiceClient(conn),
		profileID:     profileID,
	}, nil
}

// Close closes the gRPC connection
func (a *GRPCStorageAdapter) Close() error {
	return a.conn.Close()
}

// Routine operations
func (a *GRPCStorageAdapter) ListRoutines(profileID string, enabledOnly bool) ([]*models.Routine, error) {
	ctx := context.Background()
	resp, err := a.routineClient.ListRoutines(ctx, &pb.ListRoutinesRequest{
		ProfileId: profileID,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list routines: %w", err)
	}

	routines := make([]*models.Routine, 0, len(resp.Routines))
	for _, r := range resp.Routines {
		routine := protoToRoutine(r)
		// Filter by enabled status if requested
		if !enabledOnly || routine.Enabled {
			routines = append(routines, routine)
		}
	}

	return routines, nil
}

func (a *GRPCStorageAdapter) GetRoutine(id string) (*models.Routine, error) {
	ctx := context.Background()
	resp, err := a.routineClient.GetRoutine(ctx, &pb.GetRoutineRequest{
		Id: id,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to get routine: %w", err)
	}

	return protoToRoutine(resp.Routine), nil
}

func (a *GRPCStorageAdapter) CreateRoutine(id, profileID, name, description string, actionIds []string, enabled bool, metadata map[string]string) (*models.Routine, error) {
	ctx := context.Background()
	resp, err := a.routineClient.CreateRoutine(ctx, &pb.CreateRoutineRequest{
		ProfileId:   profileID,
		Name:        name,
		Description: description,
		ActionIds:   actionIds,
		Enabled:     enabled,
		Metadata:    metadata,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create routine: %w", err)
	}

	return protoToRoutine(resp.Routine), nil
}

func (a *GRPCStorageAdapter) DeleteRoutine(id string) error {
	ctx := context.Background()
	_, err := a.routineClient.DeleteRoutine(ctx, &pb.DeleteRoutineRequest{
		Id: id,
	})
	if err != nil {
		return fmt.Errorf("failed to delete routine: %w", err)
	}
	return nil
}

func (a *GRPCStorageAdapter) UpdateRoutineLastExecuted(id string) error {
	// This is handled by ExecuteRoutine in the gRPC API
	// The last_executed_at is updated automatically when a routine is executed
	// For now, we'll just return nil as this is implicitly handled
	return nil
}

// Schedule operations
func (a *GRPCStorageAdapter) ListSchedulesByRoutine(routineID string) ([]*models.Schedule, error) {
	ctx := context.Background()
	resp, err := a.scheduleClient.ListSchedules(ctx, &pb.ListSchedulesRequest{
		RoutineId: routineID,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list schedules: %w", err)
	}

	schedules := make([]*models.Schedule, 0, len(resp.Schedules))
	for _, s := range resp.Schedules {
		schedules = append(schedules, protoToSchedule(s))
	}

	return schedules, nil
}

func (a *GRPCStorageAdapter) CreateSchedule(scheduleID, routineID, name, rrule string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error) {
	ctx := context.Background()

	req := &pb.CreateScheduleRequest{
		RoutineId: routineID,
		Name:      name,
		Rrule:     rrule,
		Exdates:   exdates,
		Notes:     notes,
		Enabled:   enabled,
	}

	if dtstart != nil {
		req.Dtstart = dtstart.Format(time.RFC3339)
	}

	schedule, err := a.scheduleClient.CreateSchedule(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("failed to create schedule: %w", err)
	}

	return protoToSchedule(schedule), nil
}

func (a *GRPCStorageAdapter) DeleteSchedule(scheduleID string) error {
	ctx := context.Background()
	_, err := a.scheduleClient.DeleteSchedule(ctx, &pb.DeleteScheduleRequest{
		ScheduleId: scheduleID,
	})
	if err != nil {
		return fmt.Errorf("failed to delete schedule: %w", err)
	}
	return nil
}

// Execution log operations
func (a *GRPCStorageAdapter) CreateExecutionLog(routineID string, completed bool, notes string, actionResults map[string]string) (*models.ExecutionLog, error) {
	ctx := context.Background()
	log, err := a.routineClient.ExecuteRoutine(ctx, &pb.ExecuteRoutineRequest{
		RoutineId: routineID,
		Force:     true, // Always execute when called from MCP
		Notes:     notes,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create execution log: %w", err)
	}

	return protoToExecutionLog(log), nil
}

func (a *GRPCStorageAdapter) GetExecutionLogs(routineID string, limit int) ([]*models.ExecutionLog, error) {
	ctx := context.Background()
	resp, err := a.routineClient.GetExecutionLogs(ctx, &pb.GetExecutionLogsRequest{
		RoutineId: routineID,
		Limit:     int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to get execution logs: %w", err)
	}

	logs := make([]*models.ExecutionLog, 0, len(resp.Logs))
	for _, l := range resp.Logs {
		logs = append(logs, protoToExecutionLog(l))
	}

	return logs, nil
}

// Action operations
func (a *GRPCStorageAdapter) ListActionsByProfile(profileID string) ([]*models.Action, error) {
	ctx := context.Background()
	resp, err := a.actionClient.ListActions(ctx, &pb.ListActionsRequest{
		ProfileId: profileID,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list actions: %w", err)
	}

	actions := make([]*models.Action, 0, len(resp.Actions))
	for _, a := range resp.Actions {
		actions = append(actions, protoToAction(a))
	}

	return actions, nil
}

func (a *GRPCStorageAdapter) CreateAction(action *models.Action) error {
	ctx := context.Background()
	_, err := a.actionClient.CreateAction(ctx, &pb.CreateActionRequest{
		Id:          action.ID,
		ProfileId:   action.ProfileID,
		Type:        convertActionTypeToProto(action.Type),
		Name:        action.Name,
		Description: action.Description,
		Parameters:  action.Parameters,
		Enabled:     action.Enabled,
	})
	if err != nil {
		return fmt.Errorf("failed to create action: %w", err)
	}
	return nil
}

func (a *GRPCStorageAdapter) UpdateAction(action *models.Action) error {
	ctx := context.Background()
	_, err := a.actionClient.UpdateAction(ctx, &pb.UpdateActionRequest{
		Id:          action.ID,
		Name:        action.Name,
		Description: action.Description,
		Parameters:  action.Parameters,
		Enabled:     action.Enabled,
	})
	if err != nil {
		return fmt.Errorf("failed to update action: %w", err)
	}
	return nil
}

func (a *GRPCStorageAdapter) GetAction(actionID string) (*models.Action, error) {
	ctx := context.Background()
	resp, err := a.actionClient.GetAction(ctx, &pb.GetActionRequest{
		Id: actionID,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to get action: %w", err)
	}
	return protoToAction(resp), nil
}

func (a *GRPCStorageAdapter) DeleteAction(actionID string) error {
	ctx := context.Background()
	_, err := a.actionClient.DeleteAction(ctx, &pb.DeleteActionRequest{
		Id: actionID,
	})
	if err != nil {
		return fmt.Errorf("failed to delete action: %w", err)
	}
	return nil
}

// Helper functions to convert protobuf to models

func protoToRoutine(pb *pb.Routine) *models.Routine {
	if pb == nil {
		return nil
	}

	routine := &models.Routine{
		ID:          pb.Id,
		ProfileID:   pb.ProfileId,
		Name:        pb.Name,
		Description: pb.Description,
		ActionIDs:   pb.ActionIds,
		Enabled:     pb.Enabled,
		Metadata:    pb.Metadata,
	}

	if pb.CreatedAt != nil {
		routine.CreatedAt = pb.CreatedAt.AsTime()
	}

	if pb.UpdatedAt != nil {
		routine.UpdatedAt = pb.UpdatedAt.AsTime()
	}

	if pb.LastExecutedAt != nil {
		t := pb.LastExecutedAt.AsTime()
		routine.LastExecutedAt = &t
	}

	return routine
}

func protoToSchedule(pb *pb.Schedule) *models.Schedule {
	if pb == nil {
		return nil
	}

	schedule := &models.Schedule{
		ScheduleID: pb.ScheduleId,
		RoutineID:  pb.RoutineId,
		Name:       pb.Name,
		RRule:      pb.Rrule,
		ExDates:    pb.Exdates,
		Notes:      pb.Notes,
		Enabled:    pb.Enabled,
	}

	if pb.Dtstart != nil {
		t := pb.Dtstart.AsTime()
		schedule.DTStart = &t
	}

	if pb.LastExecution != nil {
		t := pb.LastExecution.AsTime()
		schedule.LastExecution = &t
	}

	if pb.CreatedAt != nil {
		schedule.CreatedAt = pb.CreatedAt.AsTime()
	}

	if pb.UpdatedAt != nil {
		schedule.UpdatedAt = pb.UpdatedAt.AsTime()
	}

	return schedule
}

func protoToExecutionLog(pb *pb.ExecutionLog) *models.ExecutionLog {
	if pb == nil {
		return nil
	}

	log := &models.ExecutionLog{
		LogID:         pb.LogId,
		RoutineID:     pb.RoutineId,
		Completed:     pb.Completed,
		Notes:         pb.Notes,
		ActionResults: pb.ActionResults,
	}

	if pb.Timestamp != nil {
		log.Timestamp = pb.Timestamp.AsTime()
	}

	return log
}

func protoToAction(pb *pb.Action) *models.Action {
	if pb == nil {
		return nil
	}

	// Convert proto ActionType enum to string
	actionType := convertActionType(pb.Type)

	action := &models.Action{
		ID:          pb.Id,
		ProfileID:   pb.ProfileId,
		Name:        pb.Name,
		Description: pb.Description,
		Type:        actionType,
		Parameters:  pb.Parameters,
		Enabled:     pb.Enabled,
	}

	if pb.CreatedAt != nil {
		action.CreatedAt = pb.CreatedAt.AsTime()
	}

	return action
}

// convertActionType converts proto ActionType enum to models.ActionType string
func convertActionType(protoType pb.ActionType) models.ActionType {
	switch protoType {
	case pb.ActionType_ACTION_TYPE_NOTIFICATION:
		return models.ActionTypeNotification
	case pb.ActionType_ACTION_TYPE_OPEN_LINK:
		return models.ActionTypeOpenLink
	case pb.ActionType_ACTION_TYPE_SEND_EMAIL:
		return models.ActionTypeSendEmail
	case pb.ActionType_ACTION_TYPE_RUN_SCRIPT:
		return models.ActionTypeRunScript
	case pb.ActionType_ACTION_TYPE_PLAY_SOUND:
		return models.ActionTypePlaySound
	case pb.ActionType_ACTION_TYPE_SYSTEM_COMMAND:
		return models.ActionTypeSystemCommand
	case pb.ActionType_ACTION_TYPE_API_CALL:
		return models.ActionTypeAPICall
	case pb.ActionType_ACTION_TYPE_LOG_ENTRY:
		return models.ActionTypeLogEntry
	default:
		return models.ActionTypeNotification // Default fallback
	}
}

// convertActionTypeToProto converts models.ActionType string to proto ActionType enum
func convertActionTypeToProto(actionType models.ActionType) pb.ActionType {
	switch actionType {
	case models.ActionTypeNotification:
		return pb.ActionType_ACTION_TYPE_NOTIFICATION
	case models.ActionTypeOpenLink:
		return pb.ActionType_ACTION_TYPE_OPEN_LINK
	case models.ActionTypeSendEmail:
		return pb.ActionType_ACTION_TYPE_SEND_EMAIL
	case models.ActionTypeRunScript:
		return pb.ActionType_ACTION_TYPE_RUN_SCRIPT
	case models.ActionTypePlaySound:
		return pb.ActionType_ACTION_TYPE_PLAY_SOUND
	case models.ActionTypeSystemCommand:
		return pb.ActionType_ACTION_TYPE_SYSTEM_COMMAND
	case models.ActionTypeAPICall:
		return pb.ActionType_ACTION_TYPE_API_CALL
	case models.ActionTypeLogEntry:
		return pb.ActionType_ACTION_TYPE_LOG_ENTRY
	default:
		return pb.ActionType_ACTION_TYPE_NOTIFICATION // Default fallback
	}
}
