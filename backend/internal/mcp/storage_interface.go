package mcp

import (
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// Storage defines the interface for storage operations needed by MCP server
// This allows MCP to work with both direct database and gRPC client
type Storage interface {
	// Routine operations
	ListRoutines(profileID string, enabledOnly bool) ([]*models.Routine, error)
	GetRoutine(id string) (*models.Routine, error)
	CreateRoutine(id, profileID, name, description string, actionIds []string, enabled bool, metadata map[string]string) (*models.Routine, error)
	DeleteRoutine(id string) error
	UpdateRoutineLastExecuted(id string) error

	// Schedule operations
	ListSchedulesByRoutine(routineID string) ([]*models.Schedule, error)
	CreateSchedule(scheduleID, routineID, name, rrule string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error)
	DeleteSchedule(scheduleID string) error

	// Execution log operations
	CreateExecutionLog(routineID string, completed bool, notes string, actionResults map[string]string) (*models.ExecutionLog, error)
	GetExecutionLogs(routineID string, limit int) ([]*models.ExecutionLog, error)

	// Action operations
	ListActionsByProfile(profileID string) ([]*models.Action, error)
	CreateAction(action *models.Action) error
	UpdateAction(action *models.Action) error
	GetAction(actionID string) (*models.Action, error)
	DeleteAction(actionID string) error
}
