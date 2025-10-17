package api

import (
	"context"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/validation"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// CreateAction creates a new action
func (s *Server) CreateAction(ctx context.Context, req *pb.CreateActionRequest) (*pb.Action, error) {
	// Log request details, including client-provided ID if present
	if req.Id != "" {
		s.logger.Info("Creating action with client-provided ID",
			zap.String("client_id", req.Id),
			zap.String("profile_id", req.ProfileId),
			zap.String("name", req.Name),
			zap.String("type", req.Type.String()))
	} else {
		s.logger.Info("Creating action",
			zap.String("profile_id", req.ProfileId),
			zap.String("name", req.Name),
			zap.String("type", req.Type.String()))
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

	// Convert protobuf ActionType to models.ActionType
	actionType := convertProtoActionTypeToModel(req.Type)

	// Create action model (using client-provided ID)
	action := &models.Action{
		ID:          req.Id, // Client-provided UUID
		ProfileID:   req.ProfileId,
		Type:        actionType,
		Name:        req.Name,
		Description: req.Description,
		Parameters:  req.Parameters,
		CreatedAt:   time.Now(),
	}

	// Save to database
	err := s.db.CreateAction(action)
	if err != nil {
		s.logger.Error("Failed to create action", zap.Error(err))
		// Check for duplicate ID error
		if req.Id != "" && (err.Error() == "UNIQUE constraint failed: actions.action_id" ||
			err.Error() == "action already exists") {
			return nil, status.Errorf(codes.AlreadyExists, "action with provided ID already exists")
		}
		return nil, status.Errorf(codes.Internal, "failed to create action: %v", err)
	}

	return convertToProtoAction(action), nil
}

// GetAction retrieves an action by ID
func (s *Server) GetAction(ctx context.Context, req *pb.GetActionRequest) (*pb.Action, error) {
	s.logger.Info("Getting action", zap.String("action_id", req.Id))

	action, err := s.db.GetAction(req.Id)
	if err != nil {
		s.logger.Error("Failed to get action", zap.Error(err))
		return nil, status.Errorf(codes.NotFound, "action not found: %v", err)
	}

	return convertToProtoAction(action), nil
}

// UpdateAction updates an existing action
func (s *Server) UpdateAction(ctx context.Context, req *pb.UpdateActionRequest) (*pb.Action, error) {
	s.logger.Info("Updating action", zap.String("action_id", req.Id))

	// Validate inputs
	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	// Get existing action
	action, err := s.db.GetAction(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "action not found: %v", err)
	}

	// Update fields
	action.Name = req.Name
	action.Description = req.Description
	action.Parameters = req.Parameters

	// Save updates
	err = s.db.UpdateAction(action)
	if err != nil {
		s.logger.Error("Failed to update action", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to update action: %v", err)
	}

	return convertToProtoAction(action), nil
}

// DeleteAction deletes an action
func (s *Server) DeleteAction(ctx context.Context, req *pb.DeleteActionRequest) (*emptypb.Empty, error) {
	s.logger.Info("Deleting action", zap.String("action_id", req.Id))

	// Check if action exists
	_, err := s.db.GetAction(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "action not found: %v", err)
	}

	// Delete action
	err = s.db.DeleteAction(req.Id)
	if err != nil {
		s.logger.Error("Failed to delete action", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to delete action: %v", err)
	}

	return &emptypb.Empty{}, nil
}

// ListActions lists actions for a profile
func (s *Server) ListActions(ctx context.Context, req *pb.ListActionsRequest) (*pb.ListActionsResponse, error) {
	s.logger.Info("Listing actions", zap.String("profile_id", req.ProfileId))

	var actions []*models.Action
	var err error

	// Filter by type if specified
	if req.TypeFilter != pb.ActionType_ACTION_TYPE_UNSPECIFIED {
		actionType := convertProtoActionTypeToModel(req.TypeFilter)
		actions, err = s.db.ListActionsByType(req.ProfileId, actionType)
	} else {
		actions, err = s.db.ListActionsByProfile(req.ProfileId)
	}

	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to list actions: %v", err)
	}

	// Convert to protobuf
	pbActions := make([]*pb.Action, 0, len(actions))
	for _, action := range actions {
		pbActions = append(pbActions, convertToProtoAction(action))
	}

	return &pb.ListActionsResponse{
		Actions:    pbActions,
		TotalCount: int32(len(pbActions)),
	}, nil
}

// ExecuteAction executes an action (placeholder for future implementation)
func (s *Server) ExecuteAction(ctx context.Context, req *pb.ExecuteActionRequest) (*pb.ExecuteActionResponse, error) {
	s.logger.Info("Executing action", zap.String("action_id", req.ActionId))

	// Get action
	action, err := s.db.GetAction(req.ActionId)
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "action not found: %v", err)
	}

	s.logger.Info("Found action to execute",
		zap.String("action_name", action.Name),
		zap.String("action_type", string(action.Type)))

	// TODO: Implement actual action execution logic based on action.Type
	// For now, return success placeholder
	return &pb.ExecuteActionResponse{
		Success: true,
		Result:  "Action execution not yet implemented for type: " + string(action.Type),
	}, nil
}

// ValidateAction validates an action (placeholder for future implementation)
func (s *Server) ValidateAction(ctx context.Context, req *pb.ValidateActionRequest) (*pb.ValidateActionResponse, error) {
	s.logger.Info("Validating action", zap.String("action_name", req.Action.Name))

	// TODO: Implement validation logic based on action type
	// For now, return valid
	return &pb.ValidateActionResponse{
		Valid: true,
	}, nil
}

// ListActionTypes returns available action types
func (s *Server) ListActionTypes(ctx context.Context, req *pb.ListActionTypesRequest) (*pb.ListActionTypesResponse, error) {
	s.logger.Info("Listing action types")

	// Define available action types
	actionTypes := []*pb.ActionTypeInfo{
		{
			Type:        pb.ActionType_ACTION_TYPE_NOTIFICATION,
			Name:        "Notification",
			Description: "Show system notification",
			RequiredParameters: []*pb.ParameterInfo{
				{Name: "title", Type: "string", Description: "Notification title", Required: true},
				{Name: "message", Type: "string", Description: "Notification message", Required: true},
			},
		},
		{
			Type:        pb.ActionType_ACTION_TYPE_OPEN_LINK,
			Name:        "Open Link",
			Description: "Open URL in browser",
			RequiredParameters: []*pb.ParameterInfo{
				{Name: "url", Type: "string", Description: "URL to open", Required: true},
			},
		},
	}

	return &pb.ListActionTypesResponse{
		ActionTypes: actionTypes,
	}, nil
}

// GetActionParameters returns parameters for a specific action type
func (s *Server) GetActionParameters(ctx context.Context, req *pb.GetActionParametersRequest) (*pb.GetActionParametersResponse, error) {
	s.logger.Info("Getting action parameters", zap.String("type", req.Type.String()))

	// TODO: Return parameters based on action type
	return &pb.GetActionParametersResponse{
		Parameters: []*pb.ParameterInfo{},
	}, nil
}

// Helper functions

func convertToProtoAction(action *models.Action) *pb.Action {
	return &pb.Action{
		Id:          action.ID,
		ProfileId:   action.ProfileID,
		Type:        convertModelActionTypeToProto(action.Type),
		Name:        action.Name,
		Description: action.Description,
		Parameters:  action.Parameters,
	}
}

func convertProtoActionTypeToModel(protoType pb.ActionType) models.ActionType {
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
		return models.ActionTypeNotification
	}
}

func convertModelActionTypeToProto(modelType models.ActionType) pb.ActionType {
	switch modelType {
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
		return pb.ActionType_ACTION_TYPE_UNSPECIFIED
	}
}
