package mcp

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/models"
	"go.uber.org/zap"
)

// GetTools returns the list of available MCP tools
func (s *Server) GetTools() []Tool {
	return []Tool{
		{
			Name:        "list_routines",
			Description: "List all routines for the user. Returns routine names, descriptions, enabled status, and action counts.",
			InputSchema: InputSchema{
				Type:       "object",
				Properties: map[string]interface{}{
					"enabled_only": map[string]interface{}{
						"type":        "boolean",
						"description": "If true, only return enabled routines",
					},
				},
			},
		},
		{
			Name:        "create_routine",
			Description: "Create a new routine. A routine is a named collection that can be scheduled and executed. Use this when the user wants to create a new task, habit, or workflow.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine (e.g., 'Morning Routine', 'Daily Standup')",
					},
					"description": map[string]interface{}{
						"type":        "string",
						"description": "Description of what this routine does",
					},
					"enabled": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether the routine should be enabled (default: true)",
					},
				},
				Required: []string{"name"},
			},
		},
		{
			Name:        "get_routine",
			Description: "Get detailed information about a specific routine by name or ID.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine to retrieve",
					},
				},
				Required: []string{"name"},
			},
		},
		{
			Name:        "delete_routine",
			Description: "Delete a routine permanently. This will also delete all associated schedules.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine to delete",
					},
				},
				Required: []string{"name"},
			},
		},
		{
			Name:        "create_schedule",
			Description: "Create a recurring schedule for a routine using RRule format (RFC 5545). The routine will be executed automatically according to this schedule.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"routine_name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine to schedule",
					},
					"name": map[string]interface{}{
						"type":        "string",
						"description": "Name for this schedule (e.g., 'Daily at 9am', 'Weekday mornings')",
					},
					"rrule": map[string]interface{}{
						"type":        "string",
						"description": "RRule string (e.g., 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0' for daily at 9am, 'FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=14;BYMINUTE=30' for Mon/Wed/Fri at 2:30pm)",
					},
					"enabled": map[string]interface{}{
						"type":        "boolean",
						"description": "Whether the schedule should be enabled (default: true)",
					},
				},
				Required: []string{"routine_name", "rrule"},
			},
		},
		{
			Name:        "list_schedules",
			Description: "List all schedules for a specific routine.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"routine_name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine",
					},
				},
				Required: []string{"routine_name"},
			},
		},
		{
			Name:        "delete_schedule",
			Description: "Delete a schedule permanently. Use this when the user wants to remove a recurring schedule from a routine.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"routine_name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine that has the schedule",
					},
					"schedule_name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the schedule to delete",
					},
				},
				Required: []string{"routine_name", "schedule_name"},
			},
		},
		{
			Name:        "execute_routine",
			Description: "Execute a routine immediately, outside of any schedule. Use this when the user wants to run a routine right now.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]interface{}{
					"routine_name": map[string]interface{}{
						"type":        "string",
						"description": "Name of the routine to execute",
					},
					"notes": map[string]interface{}{
						"type":        "string",
						"description": "Optional notes about this execution",
					},
				},
				Required: []string{"routine_name"},
			},
		},
	}
}

// executeTool executes a tool by name
func (s *Server) executeTool(ctx context.Context, toolName string, args map[string]interface{}) (CallToolResult, error) {
	switch toolName {
	case "list_routines":
		return s.toolListRoutines(ctx, args)
	case "create_routine":
		return s.toolCreateRoutine(ctx, args)
	case "get_routine":
		return s.toolGetRoutine(ctx, args)
	case "delete_routine":
		return s.toolDeleteRoutine(ctx, args)
	case "create_schedule":
		return s.toolCreateSchedule(ctx, args)
	case "list_schedules":
		return s.toolListSchedules(ctx, args)
	case "delete_schedule":
		return s.toolDeleteSchedule(ctx, args)
	case "execute_routine":
		return s.toolExecuteRoutine(ctx, args)
	default:
		return CallToolResult{}, fmt.Errorf("unknown tool: %s", toolName)
	}
}

// toolListRoutines lists all routines
func (s *Server) toolListRoutines(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	enabledOnly := false
	if val, ok := args["enabled_only"].(bool); ok {
		enabledOnly = val
	}

	routines, err := s.storage.ListRoutines(s.profileID, enabledOnly)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	if len(routines) == 0 {
		return CallToolResult{
			Content: []Content{TextContent("No routines found. Create your first routine to get started!")},
		}, nil
	}

	// Format routines as text
	result := fmt.Sprintf("Found %d routine(s):\n\n", len(routines))
	for i, r := range routines {
		status := "disabled"
		if r.Enabled {
			status = "enabled"
		}
		result += fmt.Sprintf("%d. **%s** (%s)\n", i+1, r.Name, status)
		if r.Description != "" {
			result += fmt.Sprintf("   %s\n", r.Description)
		}
		result += fmt.Sprintf("   ID: %s\n", r.ID)
		result += fmt.Sprintf("   Actions: %d\n", len(r.ActionIDs))
		if r.LastExecutedAt != nil {
			result += fmt.Sprintf("   Last executed: %s\n", r.LastExecutedAt.Format(time.RFC3339))
		}
		result += "\n"
	}

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolCreateRoutine creates a new routine
func (s *Server) toolCreateRoutine(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	name, ok := args["name"].(string)
	if !ok || name == "" {
		return CallToolResult{}, fmt.Errorf("name is required")
	}

	description := ""
	if val, ok := args["description"].(string); ok {
		description = val
	}

	enabled := true
	if val, ok := args["enabled"].(bool); ok {
		enabled = val
	}

	// Generate UUID for the routine
	routineID := uuid.New().String()

	// Create routine (no actions initially)
	routine, err := s.storage.CreateRoutine(routineID, s.profileID, name, description, []string{}, enabled, nil)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to create routine: %w", err)
	}

	result := fmt.Sprintf("✓ Created routine '%s'\n", routine.Name)
	result += fmt.Sprintf("  ID: %s\n", routine.ID)
	if routine.Description != "" {
		result += fmt.Sprintf("  Description: %s\n", routine.Description)
	}
	result += fmt.Sprintf("  Status: %s\n", map[bool]string{true: "enabled", false: "disabled"}[routine.Enabled])
	result += "\nNext steps:\n"
	result += "- Create a schedule for this routine using 'create_schedule'\n"
	result += "- Execute it manually using 'execute_routine'\n"

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolGetRoutine gets a routine by name
func (s *Server) toolGetRoutine(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	name, ok := args["name"].(string)
	if !ok || name == "" {
		return CallToolResult{}, fmt.Errorf("name is required")
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routine *models.Routine
	for _, r := range routines {
		if r.Name == name {
			routine = r
			break
		}
	}

	if routine == nil {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found", name))},
			IsError: true,
		}, nil
	}

	// Get schedules for this routine
	schedules, err := s.storage.ListSchedulesByRoutine(routine.ID)
	if err != nil {
		s.logger.Warn("Failed to get schedules", zap.Error(err))
	}

	// Format detailed info
	result := fmt.Sprintf("**%s**\n\n", routine.Name)
	result += fmt.Sprintf("ID: %s\n", routine.ID)
	result += fmt.Sprintf("Status: %s\n", map[bool]string{true: "enabled", false: "disabled"}[routine.Enabled])
	if routine.Description != "" {
		result += fmt.Sprintf("Description: %s\n", routine.Description)
	}
	result += fmt.Sprintf("Actions: %d\n", len(routine.ActionIDs))
	if routine.LastExecutedAt != nil {
		result += fmt.Sprintf("Last executed: %s\n", routine.LastExecutedAt.Format(time.RFC3339))
	}
	result += fmt.Sprintf("Created: %s\n", routine.CreatedAt.Format(time.RFC3339))

	if len(schedules) > 0 {
		result += fmt.Sprintf("\nSchedules (%d):\n", len(schedules))
		for i, sched := range schedules {
			status := "disabled"
			if sched.Enabled {
				status = "enabled"
			}
			result += fmt.Sprintf("%d. %s (%s)\n", i+1, sched.Name, status)
			result += fmt.Sprintf("   RRule: %s\n", sched.RRule)
		}
	} else {
		result += "\nNo schedules configured.\n"
	}

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolDeleteRoutine deletes a routine
func (s *Server) toolDeleteRoutine(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	name, ok := args["name"].(string)
	if !ok || name == "" {
		return CallToolResult{}, fmt.Errorf("name is required")
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routineID string
	for _, r := range routines {
		if r.Name == name {
			routineID = r.ID
			break
		}
	}

	if routineID == "" {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found", name))},
			IsError: true,
		}, nil
	}

	// Delete the routine
	if err := s.storage.DeleteRoutine(routineID); err != nil {
		return CallToolResult{}, fmt.Errorf("failed to delete routine: %w", err)
	}

	return CallToolResult{
		Content: []Content{TextContent(fmt.Sprintf("✓ Deleted routine '%s'", name))},
	}, nil
}

// toolCreateSchedule creates a schedule for a routine
func (s *Server) toolCreateSchedule(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	routineName, ok := args["routine_name"].(string)
	if !ok || routineName == "" {
		return CallToolResult{}, fmt.Errorf("routine_name is required")
	}

	rrule, ok := args["rrule"].(string)
	if !ok || rrule == "" {
		return CallToolResult{}, fmt.Errorf("rrule is required")
	}

	scheduleName := ""
	if val, ok := args["name"].(string); ok {
		scheduleName = val
	}
	if scheduleName == "" {
		scheduleName = "Schedule"
	}

	enabled := true
	if val, ok := args["enabled"].(bool); ok {
		enabled = val
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routineID string
	for _, r := range routines {
		if r.Name == routineName {
			routineID = r.ID
			break
		}
	}

	if routineID == "" {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found. Create it first using 'create_routine'.", routineName))},
			IsError: true,
		}, nil
	}

	// Generate UUID for schedule
	scheduleID := uuid.New().String()

	// Create schedule
	now := time.Now()
	schedule, err := s.storage.CreateSchedule(scheduleID, routineID, scheduleName, rrule, &now, []string{}, "", enabled)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to create schedule: %w", err)
	}

	result := fmt.Sprintf("✓ Created schedule '%s' for routine '%s'\n", schedule.Name, routineName)
	result += fmt.Sprintf("  ID: %s\n", schedule.ScheduleID)
	result += fmt.Sprintf("  RRule: %s\n", schedule.RRule)
	result += fmt.Sprintf("  Status: %s\n", map[bool]string{true: "enabled", false: "disabled"}[schedule.Enabled])
	result += "\nThe routine will now execute automatically according to this schedule.\n"

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolListSchedules lists schedules for a routine
func (s *Server) toolListSchedules(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	routineName, ok := args["routine_name"].(string)
	if !ok || routineName == "" {
		return CallToolResult{}, fmt.Errorf("routine_name is required")
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routineID string
	for _, r := range routines {
		if r.Name == routineName {
			routineID = r.ID
			break
		}
	}

	if routineID == "" {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found", routineName))},
			IsError: true,
		}, nil
	}

	schedules, err := s.storage.ListSchedulesByRoutine(routineID)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list schedules: %w", err)
	}

	if len(schedules) == 0 {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("No schedules found for routine '%s'", routineName))},
		}, nil
	}

	result := fmt.Sprintf("Schedules for '%s' (%d):\n\n", routineName, len(schedules))
	for i, sched := range schedules {
		status := "disabled"
		if sched.Enabled {
			status = "enabled"
		}
		result += fmt.Sprintf("%d. **%s** (%s)\n", i+1, sched.Name, status)
		result += fmt.Sprintf("   RRule: %s\n", sched.RRule)
		result += fmt.Sprintf("   ID: %s\n", sched.ScheduleID)
		if sched.LastExecution != nil {
			result += fmt.Sprintf("   Last executed: %s\n", sched.LastExecution.Format(time.RFC3339))
		}
		result += "\n"
	}

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolDeleteSchedule deletes a schedule
func (s *Server) toolDeleteSchedule(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	routineName, ok := args["routine_name"].(string)
	if !ok || routineName == "" {
		return CallToolResult{}, fmt.Errorf("routine_name is required")
	}

	scheduleName, ok := args["schedule_name"].(string)
	if !ok || scheduleName == "" {
		return CallToolResult{}, fmt.Errorf("schedule_name is required")
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routineID string
	for _, r := range routines {
		if r.Name == routineName {
			routineID = r.ID
			break
		}
	}

	if routineID == "" {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found", routineName))},
			IsError: true,
		}, nil
	}

	// Find schedule by name within the routine
	schedules, err := s.storage.ListSchedulesByRoutine(routineID)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list schedules: %w", err)
	}

	var scheduleID string
	for _, sched := range schedules {
		if sched.Name == scheduleName {
			scheduleID = sched.ScheduleID
			break
		}
	}

	if scheduleID == "" {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Schedule '%s' not found for routine '%s'", scheduleName, routineName))},
			IsError: true,
		}, nil
	}

	// Delete the schedule
	if err := s.storage.DeleteSchedule(scheduleID); err != nil {
		return CallToolResult{}, fmt.Errorf("failed to delete schedule: %w", err)
	}

	result := fmt.Sprintf("✓ Deleted schedule '%s' from routine '%s'", scheduleName, routineName)

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}

// toolExecuteRoutine executes a routine immediately
func (s *Server) toolExecuteRoutine(ctx context.Context, args map[string]interface{}) (CallToolResult, error) {
	routineName, ok := args["routine_name"].(string)
	if !ok || routineName == "" {
		return CallToolResult{}, fmt.Errorf("routine_name is required")
	}

	notes := ""
	if val, ok := args["notes"].(string); ok {
		notes = val
	}

	// Find routine by name
	routines, err := s.storage.ListRoutines(s.profileID, false)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to list routines: %w", err)
	}

	var routine *models.Routine
	for _, r := range routines {
		if r.Name == routineName {
			routine = r
			break
		}
	}

	if routine == nil {
		return CallToolResult{
			Content: []Content{TextContent(fmt.Sprintf("Routine '%s' not found", routineName))},
			IsError: true,
		}, nil
	}

	// Create execution log
	actionResults := make(map[string]string)
	execLog, err := s.storage.CreateExecutionLog(routine.ID, true, notes, actionResults)
	if err != nil {
		return CallToolResult{}, fmt.Errorf("failed to create execution log: %w", err)
	}

	// Update routine's last executed timestamp
	if err := s.storage.UpdateRoutineLastExecuted(routine.ID); err != nil {
		s.logger.Warn("Failed to update routine last executed", zap.Error(err))
	}

	result := fmt.Sprintf("✓ Executed routine '%s'\n", routine.Name)
	result += fmt.Sprintf("  Execution time: %s\n", execLog.Timestamp.Format(time.RFC3339))
	if notes != "" {
		result += fmt.Sprintf("  Notes: %s\n", notes)
	}
	if len(routine.ActionIDs) > 0 {
		result += fmt.Sprintf("  Actions executed: %d\n", len(routine.ActionIDs))
	} else {
		result += "  Note: This routine has no actions configured yet.\n"
	}

	return CallToolResult{
		Content: []Content{TextContent(result)},
	}, nil
}
