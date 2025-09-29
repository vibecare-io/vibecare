package storage

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateSchedule creates a new schedule
func (db *DB) CreateSchedule(scheduleID, routineID, name, recurrenceJSON string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error) {
	// Generate UUID if not provided (client-authoritative ID pattern)
	if scheduleID == "" {
		scheduleID = uuid.New().String()
	} else {
		// Validate provided UUID
		if _, err := uuid.Parse(scheduleID); err != nil {
			return nil, fmt.Errorf("invalid schedule ID format - must be valid UUID")
		}
	}

	// Check if schedule with this ID already exists
	existing, err := db.GetSchedule(scheduleID)
	if err != nil {
		return nil, err
	}
	if existing != nil {
		return nil, fmt.Errorf("schedule with ID %s already exists", scheduleID)
	}

	schedule := &models.Schedule{
		ScheduleID:     scheduleID,
		RoutineID:      routineID,
		Name:           name,
		RecurrenceJSON: recurrenceJSON,
		DTStart:        dtstart,
		ExDates:        exdates,
		Notes:          notes,
		Enabled:        enabled,
		CreatedAt:      time.Now(),
		UpdatedAt:      time.Now(),
	}

	query := `
		INSERT INTO schedules (schedule_id, routine_id, name, recurrence_json, dtstart, exdates, notes, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`

	var dtStartStr sql.NullString
	if dtstart != nil {
		dtStartStr.Valid = true
		dtStartStr.String = dtstart.Format(time.RFC3339)
	}

	var exdatesStr sql.NullString
	if len(exdates) > 0 {
		exdatesStr.Valid = true
		exdatesStr.String = strings.Join(exdates, ",")
	}

	_, err = db.Exec(query,
		schedule.ScheduleID,
		schedule.RoutineID,
		schedule.Name,
		schedule.RecurrenceJSON,
		dtStartStr,
		exdatesStr,
		schedule.Notes,
		schedule.Enabled,
		schedule.CreatedAt.Format(time.RFC3339),
		schedule.UpdatedAt.Format(time.RFC3339),
	)

	if err != nil {
		return nil, err
	}

	return schedule, nil
}

// GetSchedule retrieves a schedule by ID
func (db *DB) GetSchedule(id string) (*models.Schedule, error) {
	query := `
		SELECT schedule_id, routine_id, name, recurrence_json, dtstart, exdates,
		       last_execution, notes, enabled, created_at, updated_at
		FROM schedules
		WHERE schedule_id = ?
	`

	var schedule models.Schedule
	var dtstart, lastExecution, exdatesStr sql.NullString
	var createdAt, updatedAt string

	err := db.QueryRow(query, id).Scan(
		&schedule.ScheduleID,
		&schedule.RoutineID,
		&schedule.Name,
		&schedule.RecurrenceJSON,
		&dtstart,
		&exdatesStr,
		&lastExecution,
		&schedule.Notes,
		&schedule.Enabled,
		&createdAt,
		&updatedAt,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	if dtstart.Valid {
		t, _ := time.Parse(time.RFC3339, dtstart.String)
		schedule.DTStart = &t
	}

	if lastExecution.Valid {
		t, _ := time.Parse(time.RFC3339, lastExecution.String)
		schedule.LastExecution = &t
	}

	if exdatesStr.Valid && exdatesStr.String != "" {
		schedule.ExDates = strings.Split(exdatesStr.String, ",")
	}

	schedule.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	schedule.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &schedule, nil
}

// ListSchedulesByRoutine lists all schedules for a routine
func (db *DB) ListSchedulesByRoutine(routineID string) ([]*models.Schedule, error) {
	query := `
		SELECT schedule_id, routine_id, name, recurrence_json, dtstart, exdates,
		       last_execution, notes, enabled, created_at, updated_at
		FROM schedules
		WHERE routine_id = ?
		ORDER BY created_at DESC
	`

	rows, err := db.Query(query, routineID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var schedules []*models.Schedule
	for rows.Next() {
		var schedule models.Schedule
		var dtstart, lastExecution, exdatesStr sql.NullString
		var createdAt, updatedAt string

		err := rows.Scan(
			&schedule.ScheduleID,
			&schedule.RoutineID,
			&schedule.Name,
			&schedule.RecurrenceJSON,
			&dtstart,
			&exdatesStr,
			&lastExecution,
			&schedule.Notes,
			&schedule.Enabled,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		if dtstart.Valid {
			t, _ := time.Parse(time.RFC3339, dtstart.String)
			schedule.DTStart = &t
		}

		if lastExecution.Valid {
			t, _ := time.Parse(time.RFC3339, lastExecution.String)
			schedule.LastExecution = &t
		}

		if exdatesStr.Valid && exdatesStr.String != "" {
			schedule.ExDates = strings.Split(exdatesStr.String, ",")
		}

		schedule.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		schedule.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

		schedules = append(schedules, &schedule)
	}

	return schedules, nil
}

// UpdateSchedule updates an existing schedule
func (db *DB) UpdateSchedule(schedule *models.Schedule) (*models.Schedule, error) {
	schedule.UpdatedAt = time.Now()

	query := `
		UPDATE schedules
		SET name = ?, recurrence_json = ?, dtstart = ?, exdates = ?, notes = ?, enabled = ?, updated_at = ?
		WHERE schedule_id = ?
	`

	var dtStartStr sql.NullString
	if schedule.DTStart != nil {
		dtStartStr.Valid = true
		dtStartStr.String = schedule.DTStart.Format(time.RFC3339)
	}

	var exdatesStr sql.NullString
	if len(schedule.ExDates) > 0 {
		exdatesStr.Valid = true
		exdatesStr.String = strings.Join(schedule.ExDates, ",")
	}

	_, err := db.Exec(query,
		schedule.Name,
		schedule.RecurrenceJSON,
		dtStartStr,
		exdatesStr,
		schedule.Notes,
		schedule.Enabled,
		schedule.UpdatedAt.Format(time.RFC3339),
		schedule.ScheduleID,
	)

	if err != nil {
		return nil, err
	}

	return schedule, nil
}

// DeleteSchedule deletes a schedule
func (db *DB) DeleteSchedule(scheduleID string) error {
	query := `DELETE FROM schedules WHERE schedule_id = ?`
	_, err := db.Exec(query, scheduleID)
	return err
}

// EnableSchedule enables/disables a schedule
func (db *DB) EnableSchedule(scheduleID string, enabled bool) error {
	query := `
		UPDATE schedules
		SET enabled = ?, updated_at = ?
		WHERE schedule_id = ?
	`
	_, err := db.Exec(query, enabled, time.Now().Format(time.RFC3339), scheduleID)
	return err
}

// UpdateLastExecution updates the last execution time for a schedule
func (db *DB) UpdateLastExecution(scheduleID string, executionTime time.Time) error {
	query := `
		UPDATE schedules
		SET last_execution = ?, updated_at = ?
		WHERE schedule_id = ?
	`

	_, err := db.Exec(query,
		executionTime.Format(time.RFC3339),
		time.Now().Format(time.RFC3339),
		scheduleID,
	)
	return err
}

// GetActiveSchedules retrieves all enabled schedules
func (db *DB) GetActiveSchedules() ([]*models.Schedule, error) {
	query := `
		SELECT s.schedule_id, s.routine_id, s.name, s.recurrence_json, s.dtstart, s.exdates,
		       s.last_execution, s.notes, s.enabled, s.created_at, s.updated_at
		FROM schedules s
		INNER JOIN routines r ON s.routine_id = r.id
		WHERE s.enabled = 1 AND r.enabled = 1
		ORDER BY s.created_at DESC
	`

	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var schedules []*models.Schedule
	for rows.Next() {
		var schedule models.Schedule
		var dtstart, lastExecution, exdatesStr sql.NullString
		var createdAt, updatedAt string

		err := rows.Scan(
			&schedule.ScheduleID,
			&schedule.RoutineID,
			&schedule.Name,
			&schedule.RecurrenceJSON,
			&dtstart,
			&exdatesStr,
			&lastExecution,
			&schedule.Notes,
			&schedule.Enabled,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		if dtstart.Valid {
			t, _ := time.Parse(time.RFC3339, dtstart.String)
			schedule.DTStart = &t
		}

		if lastExecution.Valid {
			t, _ := time.Parse(time.RFC3339, lastExecution.String)
			schedule.LastExecution = &t
		}

		if exdatesStr.Valid && exdatesStr.String != "" {
			schedule.ExDates = strings.Split(exdatesStr.String, ",")
		}

		schedule.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		schedule.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

		schedules = append(schedules, &schedule)
	}

	return schedules, nil
}
