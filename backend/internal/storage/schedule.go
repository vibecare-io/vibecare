package storage

import (
	"database/sql"
	"strings"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateSchedule creates a new schedule
func (db *DB) CreateSchedule(routineID, name, recurrenceJSON string, dtstart *time.Time) (*models.Schedule, error) {
	schedule := &models.Schedule{
		RoutineID:      routineID,
		Name:           name,
		RecurrenceJSON: recurrenceJSON,
		DTStart:        dtstart,
		Enabled:        true,
		CreatedAt:      time.Now(),
		UpdatedAt:      time.Now(),
	}

	query := `
		INSERT INTO schedules (routine_id, name, recurrence_json, dtstart, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`

	var dtStartStr sql.NullString
	if dtstart != nil {
		dtStartStr.Valid = true
		dtStartStr.String = dtstart.Format(time.RFC3339)
	}

	result, err := db.Exec(query,
		schedule.RoutineID,
		schedule.Name,
		schedule.RecurrenceJSON,
		dtStartStr,
		schedule.Enabled,
		schedule.CreatedAt.Format(time.RFC3339),
		schedule.UpdatedAt.Format(time.RFC3339),
	)

	if err != nil {
		return nil, err
	}

	schedule.ScheduleID, _ = result.LastInsertId()
	return schedule, nil
}

// GetSchedule retrieves a schedule by ID
func (db *DB) GetSchedule(id int64) (*models.Schedule, error) {
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

// UpdateLastExecution updates the last execution time for a schedule
func (db *DB) UpdateLastExecution(scheduleID int64, executionTime time.Time) error {
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
