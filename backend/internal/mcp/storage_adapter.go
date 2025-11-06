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

func (a *DBStorageAdapter) CreateRoutine(id, profileID, name, description string, enabled bool, metadata map[string]string) (*models.Routine, error) {
	return a.db.CreateRoutine(id, profileID, name, description, enabled, metadata)
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

func (a *DBStorageAdapter) GetSchedule(scheduleID string) (*models.Schedule, error) {
	return a.db.GetSchedule(scheduleID)
}

func (a *DBStorageAdapter) CreateSchedule(scheduleID, profileID, routineID, name, rrule string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error) {
	return a.db.CreateSchedule(scheduleID, profileID, routineID, name, rrule, dtstart, exdates, notes, enabled)
}

func (a *DBStorageAdapter) UpdateSchedule(schedule *models.Schedule) (*models.Schedule, error) {
	return a.db.UpdateSchedule(schedule)
}

func (a *DBStorageAdapter) DeleteSchedule(scheduleID string) error {
	return a.db.DeleteSchedule(scheduleID)
}

// Action operations
func (a *DBStorageAdapter) ListActionsByProfile(profileID string) ([]*models.Action, error) {
	return a.db.ListActionsByProfile(profileID)
}

func (a *DBStorageAdapter) CreateAction(action *models.Action) error {
	return a.db.CreateAction(action)
}

func (a *DBStorageAdapter) UpdateAction(action *models.Action) error {
	return a.db.UpdateAction(action)
}

func (a *DBStorageAdapter) GetAction(actionID string) (*models.Action, error) {
	return a.db.GetAction(actionID)
}

func (a *DBStorageAdapter) DeleteAction(actionID string) error {
	return a.db.DeleteAction(actionID)
}
