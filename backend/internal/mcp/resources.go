package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"go.uber.org/zap"
)

// GetResources returns the list of available MCP resources
func (s *Server) GetResources() []Resource {
	return []Resource{
		{
			URI:         "vibecare://routines",
			Name:        "Routines List",
			Description: "List of all routines with their details",
			MimeType:    "application/json",
		},
		{
			URI:         "vibecare://schedules",
			Name:        "Schedules List",
			Description: "List of all schedules across all routines",
			MimeType:    "application/json",
		},
		{
			URI:         "vibecare://actions",
			Name:        "Actions List",
			Description: "List of all available actions",
			MimeType:    "application/json",
		},
		{
			URI:         "vibecare://execution-logs",
			Name:        "Execution Logs",
			Description: "Recent routine execution history",
			MimeType:    "application/json",
		},
	}
}

// readResource reads a specific resource by URI
func (s *Server) readResource(ctx context.Context, uri string) ([]ResourceContents, error) {
	switch {
	case uri == "vibecare://routines":
		return s.readRoutinesResource(ctx)
	case uri == "vibecare://schedules":
		return s.readSchedulesResource(ctx)
	case uri == "vibecare://actions":
		return s.readActionsResource(ctx)
	case uri == "vibecare://execution-logs":
		return s.readExecutionLogsResource(ctx)
	case strings.HasPrefix(uri, "vibecare://routines/"):
		// Individual routine by ID
		routineID := strings.TrimPrefix(uri, "vibecare://routines/")
		return s.readRoutineResource(ctx, routineID)
	default:
		return nil, fmt.Errorf("unknown resource URI: %s", uri)
	}
}

// readRoutinesResource returns all routines as JSON
func (s *Server) readRoutinesResource(ctx context.Context) ([]ResourceContents, error) {
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return nil, fmt.Errorf("failed to list routines: %w", err)
	}

	// Convert to JSON
	data, err := json.MarshalIndent(routines, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("failed to marshal routines: %w", err)
	}

	return []ResourceContents{
		{
			URI:      "vibecare://routines",
			MimeType: "application/json",
			Text:     string(data),
		},
	}, nil
}

// readRoutineResource returns a specific routine by ID
func (s *Server) readRoutineResource(ctx context.Context, routineID string) ([]ResourceContents, error) {
	routine, err := s.storage.GetRoutine(routineID)
	if err != nil {
		return nil, fmt.Errorf("failed to get routine: %w", err)
	}

	// Get schedules for this routine
	schedules, err := s.storage.ListSchedulesByRoutine(routineID)
	if err != nil {
		s.logger.Warn("Failed to get schedules for routine", zap.String("routine_id", routineID), zap.Error(err))
	}

	// Build comprehensive response
	response := map[string]interface{}{
		"routine":   routine,
		"schedules": schedules,
	}

	data, err := json.MarshalIndent(response, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("failed to marshal routine: %w", err)
	}

	return []ResourceContents{
		{
			URI:      fmt.Sprintf("vibecare://routines/%s", routineID),
			MimeType: "application/json",
			Text:     string(data),
		},
	}, nil
}

// readSchedulesResource returns all schedules as JSON
func (s *Server) readSchedulesResource(ctx context.Context) ([]ResourceContents, error) {
	// Get all routines first
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return nil, fmt.Errorf("failed to list routines: %w", err)
	}

	// Collect all schedules
	type ScheduleWithRoutine struct {
		Schedule    interface{} `json:"schedule"`
		RoutineName string      `json:"routine_name"`
		RoutineID   string      `json:"routine_id"`
	}

	var allSchedules []ScheduleWithRoutine
	for _, routine := range routines {
		schedules, err := s.storage.ListSchedulesByRoutine(routine.ID)
		if err != nil {
			s.logger.Warn("Failed to get schedules for routine", zap.String("routine_id", routine.ID), zap.Error(err))
			continue
		}

		for _, sched := range schedules {
			allSchedules = append(allSchedules, ScheduleWithRoutine{
				Schedule:    sched,
				RoutineName: routine.Name,
				RoutineID:   routine.ID,
			})
		}
	}

	data, err := json.MarshalIndent(allSchedules, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("failed to marshal schedules: %w", err)
	}

	return []ResourceContents{
		{
			URI:      "vibecare://schedules",
			MimeType: "application/json",
			Text:     string(data),
		},
	}, nil
}

// readActionsResource returns all actions as JSON
func (s *Server) readActionsResource(ctx context.Context) ([]ResourceContents, error) {
	actions, err := s.storage.ListActionsByProfile(s.profileID)
	if err != nil {
		return nil, fmt.Errorf("failed to list actions: %w", err)
	}

	data, err := json.MarshalIndent(actions, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("failed to marshal actions: %w", err)
	}

	return []ResourceContents{
		{
			URI:      "vibecare://actions",
			MimeType: "application/json",
			Text:     string(data),
		},
	}, nil
}

// readExecutionLogsResource returns recent execution logs as JSON
// DEPRECATED: Execution logs have been removed from the schema
func (s *Server) readExecutionLogsResource(ctx context.Context) ([]ResourceContents, error) {
	s.logger.Warn("readExecutionLogsResource called but execution logs are deprecated")

	// Return empty array for backward compatibility
	data := []byte("[]")

	return []ResourceContents{
		{
			URI:      "vibecare://execution-logs",
			MimeType: "application/json",
			Text:     string(data),
		},
	}, nil
}
