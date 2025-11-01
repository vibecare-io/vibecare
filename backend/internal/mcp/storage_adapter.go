package mcp

import (
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
)

// DBStorageAdapter adapts storage.DB to implement the Storage interface
type DBStorageAdapter struct {
	db *storage.DB
}

// NewDBStorageAdapter creates a new adapter for direct database access
func NewDBStorageAdapter(db *storage.DB) Storage {
	return &DBStorageAdapter{db: db}
}

// Routine operations
func (a *DBStorageAdapter) ListRoutines(profileID string, enabledOnly bool) ([]*models.Routine, error) {
	return a.db.ListRoutines(profileID, enabledOnly)
}

func (a *DBStorageAdapter) GetRoutine(id string) (*models.Routine, error) {
	return a.db.GetRoutine(id)
}

func (a *DBStorageAdapter) CreateRoutine(id, profileID, name, description string, actionIds []string, enabled bool, metadata map[string]string) (*models.Routine, error) {
	return a.db.CreateRoutine(id, profileID, name, description, actionIds, enabled, metadata)
}

func (a *DBStorageAdapter) DeleteRoutine(id string) error {
	return a.db.DeleteRoutine(id)
}

func (a *DBStorageAdapter) UpdateRoutineLastExecuted(id string) error {
	return a.db.UpdateRoutineLastExecuted(id)
}

// Schedule operations
func (a *DBStorageAdapter) ListSchedulesByRoutine(routineID string) ([]*models.Schedule, error) {
	return a.db.ListSchedulesByRoutine(routineID)
}

func (a *DBStorageAdapter) CreateSchedule(scheduleID, routineID, name, rrule string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error) {
	return a.db.CreateSchedule(scheduleID, routineID, name, rrule, dtstart, exdates, notes, enabled, []string{})
}

func (a *DBStorageAdapter) DeleteSchedule(scheduleID string) error {
	return a.db.DeleteSchedule(scheduleID)
}

// Execution log operations
func (a *DBStorageAdapter) CreateExecutionLog(routineID string, completed bool, notes string, actionResults map[string]string) (*models.ExecutionLog, error) {
	return a.db.CreateExecutionLog(routineID, completed, notes, actionResults)
}

func (a *DBStorageAdapter) GetExecutionLogs(routineID string, limit int) ([]*models.ExecutionLog, error) {
	return a.db.GetExecutionLogs(routineID, limit)
}

// Action operations
func (a *DBStorageAdapter) ListActionsByProfile(profileID string) ([]*models.Action, error) {
	return a.db.ListActionsByProfile(profileID)
}
