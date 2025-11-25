package storage

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/teambition/rrule-go"
	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/validation"
)

// calculateNextFromRRule calculates the next execution time based on an RRule string.
// Returns zero time if the rrule is empty, invalid, or has no future occurrences.
func calculateNextFromRRule(rruleStr string, dtstart, after time.Time) (time.Time, error) {
	// Empty rrule means one-time event (no next execution)
	if strings.TrimSpace(rruleStr) == "" {
		return time.Time{}, fmt.Errorf("empty rrule")
	}

	// Build complete RRule string with DTSTART
	fullRRule := "DTSTART:" + dtstart.Format("20060102T150405Z") + "\nRRULE:" + rruleStr

	// Parse the RRule using rrule-go library
	rule, err := rrule.StrToRRule(fullRRule)
	if err != nil {
		return time.Time{}, fmt.Errorf("failed to parse rrule: %w", err)
	}

	// Create RSet and add the rule
	rset := &rrule.Set{}
	rset.RRule(rule)

	// Get the next occurrence after the given time
	next := rset.After(after, false)

	return next, nil
}

// CreateSchedule creates a new schedule
func (db *DB) CreateSchedule(scheduleID, profileID, routineID, name, rrule, scheduleTimezone string, dtstart *time.Time, exdates []string, notes string, enabled bool) (*models.Schedule, error) {
	// Validate and sanitize inputs
	if err := validation.ValidateUUID("schedule_id", scheduleID); err != nil {
		return nil, err
	}

	if err := validation.ValidateRequired("profile_id", profileID); err != nil {
		return nil, err
	}

	if err := validation.ValidateRequired("routine_id", routineID); err != nil {
		return nil, err
	}

	sanitizedName, err := validation.ValidateAndSanitizeName("name", name)
	if err != nil {
		return nil, err
	}

	// Validate RRule (empty string allowed for one-time events)
	if err := validation.ValidateRRule(rrule); err != nil {
		return nil, err
	}

	if err := validation.ValidateStringArray("exdates", exdates, validation.MaxArraySize); err != nil {
		return nil, err
	}

	sanitizedNotes, err := validation.ValidateAndSanitizeNotes(notes)
	if err != nil {
		return nil, err
	}

	// Default to UTC if timezone is empty
	if scheduleTimezone == "" {
		scheduleTimezone = "UTC"
	}

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

	// Validate that the routine exists (FOREIGN KEY validation)
	routine, err := db.GetRoutine(routineID)
	if err != nil {
		return nil, fmt.Errorf("failed to validate routine: %w", err)
	}
	if routine == nil {
		return nil, fmt.Errorf("routine with ID %s does not exist", routineID)
	}

	// Determine schedule type based on rrule
	scheduleType := models.ScheduleTypeRecurring
	if strings.TrimSpace(rrule) == "" {
		scheduleType = models.ScheduleTypeOneShot
	}

	// Calculate initial next_execution
	var nextExecution *time.Time
	if scheduleType == models.ScheduleTypeOneShot {
		// For one-time events, next_execution is dtstart (if in future)
		if dtstart != nil && dtstart.After(time.Now()) {
			nextExecution = dtstart
		}
	} else {
		// For recurring events, calculate from rrule
		if dtstart != nil {
			nextTime, err := calculateNextFromRRule(rrule, *dtstart, time.Now())
			if err == nil && !nextTime.IsZero() {
				nextExecution = &nextTime
			}
		}
	}

	schedule := &models.Schedule{
		ScheduleID:       scheduleID,
		ProfileID:        profileID,
		RoutineID:        routineID,
		ScheduleType:     scheduleType,
		Name:             sanitizedName,
		RRule:            rrule,
		ScheduleTimezone: scheduleTimezone,
		DTStart:          dtstart,
		ExDates:          exdates,
		NextExecution:    nextExecution,
		Notes:            sanitizedNotes,
		Enabled:          enabled,
		CreatedAt:        time.Now().UTC(),
		UpdatedAt:        time.Now().UTC(),
	}

	query := `
		INSERT INTO schedules (schedule_id, profile_id, routine_id, schedule_type, name, rrule, schedule_timezone, dtstart, exdates, next_execution, notes, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

	var nextExecStr sql.NullString
	if nextExecution != nil {
		nextExecStr.Valid = true
		nextExecStr.String = nextExecution.Format(time.RFC3339)
	}

	_, err = db.Exec(query,
		schedule.ScheduleID,
		schedule.ProfileID,
		schedule.RoutineID,
		string(schedule.ScheduleType),
		schedule.Name,
		schedule.RRule,
		schedule.ScheduleTimezone,
		dtStartStr,
		exdatesStr,
		nextExecStr,
		schedule.Notes,
		schedule.Enabled,
		schedule.CreatedAt.UTC().Format(time.RFC3339),
		schedule.UpdatedAt.UTC().Format(time.RFC3339),
	)

	if err != nil {
		return nil, err
	}

	return schedule, nil
}

// GetSchedule retrieves a schedule by ID
func (db *DB) GetSchedule(id string) (*models.Schedule, error) {
	query := `
		SELECT schedule_id, profile_id, routine_id, schedule_type, name, rrule, schedule_timezone, dtstart, exdates,
		       last_execution, next_execution, notes, enabled, created_at, updated_at
		FROM schedules
		WHERE schedule_id = ?
	`

	var schedule models.Schedule
	var scheduleType string
	var dtstart, lastExecution, nextExecution, exdatesStr sql.NullString
	var createdAt, updatedAt string

	err := db.QueryRow(query, id).Scan(
		&schedule.ScheduleID,
		&schedule.ProfileID,
		&schedule.RoutineID,
		&scheduleType,
		&schedule.Name,
		&schedule.RRule,
		&schedule.ScheduleTimezone,
		&dtstart,
		&exdatesStr,
		&lastExecution,
		&nextExecution,
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

	schedule.ScheduleType = models.ScheduleType(scheduleType)

	if dtstart.Valid {
		t, parseErr := time.Parse(time.RFC3339, dtstart.String)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse dtstart: %w", parseErr)
		}
		schedule.DTStart = &t
	}

	if lastExecution.Valid {
		t, parseErr := time.Parse(time.RFC3339, lastExecution.String)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse last_execution: %w", parseErr)
		}
		schedule.LastExecution = &t
	}

	if nextExecution.Valid {
		t, parseErr := time.Parse(time.RFC3339, nextExecution.String)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse next_execution: %w", parseErr)
		}
		schedule.NextExecution = &t
	}

	if exdatesStr.Valid && exdatesStr.String != "" {
		schedule.ExDates = strings.Split(exdatesStr.String, ",")
	}

	var parseErr error
	schedule.CreatedAt, parseErr = time.Parse(time.RFC3339, createdAt)
	if parseErr != nil {
		return nil, fmt.Errorf("failed to parse created_at: %w", parseErr)
	}

	schedule.UpdatedAt, parseErr = time.Parse(time.RFC3339, updatedAt)
	if parseErr != nil {
		return nil, fmt.Errorf("failed to parse updated_at: %w", parseErr)
	}

	return &schedule, nil
}

// ListSchedulesByRoutine lists all schedules for a routine
func (db *DB) ListSchedulesByRoutine(routineID string) ([]*models.Schedule, error) {
	query := `
		SELECT schedule_id, profile_id, routine_id, schedule_type, name, rrule, schedule_timezone, dtstart, exdates,
		       last_execution, next_execution, notes, enabled, created_at, updated_at
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
		var scheduleType string
		var dtstart, lastExecution, nextExecution, exdatesStr sql.NullString
		var createdAt, updatedAt string

		err := rows.Scan(
			&schedule.ScheduleID,
			&schedule.ProfileID,
			&schedule.RoutineID,
			&scheduleType,
			&schedule.Name,
			&schedule.RRule,
			&schedule.ScheduleTimezone,
			&dtstart,
			&exdatesStr,
			&lastExecution,
			&nextExecution,
			&schedule.Notes,
			&schedule.Enabled,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		schedule.ScheduleType = models.ScheduleType(scheduleType)

		if dtstart.Valid {
			t, parseErr := time.Parse(time.RFC3339, dtstart.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse dtstart for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.DTStart = &t
		}

		if lastExecution.Valid {
			t, parseErr := time.Parse(time.RFC3339, lastExecution.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse last_execution for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.LastExecution = &t
		}

		if nextExecution.Valid {
			t, parseErr := time.Parse(time.RFC3339, nextExecution.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse next_execution for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.NextExecution = &t
		}

		if exdatesStr.Valid && exdatesStr.String != "" {
			schedule.ExDates = strings.Split(exdatesStr.String, ",")
		}

		var parseErr error
		schedule.CreatedAt, parseErr = time.Parse(time.RFC3339, createdAt)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse created_at for schedule %s: %w", schedule.ScheduleID, parseErr)
		}

		schedule.UpdatedAt, parseErr = time.Parse(time.RFC3339, updatedAt)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse updated_at for schedule %s: %w", schedule.ScheduleID, parseErr)
		}

		schedules = append(schedules, &schedule)
	}

	return schedules, nil
}

// UpdateSchedule updates an existing schedule
func (db *DB) UpdateSchedule(schedule *models.Schedule) (*models.Schedule, error) {
	// Validate and sanitize inputs
	sanitizedName, err := validation.ValidateAndSanitizeName("name", schedule.Name)
	if err != nil {
		return nil, err
	}
	schedule.Name = sanitizedName

	// Validate RRule (empty string allowed for one-time events)
	if err := validation.ValidateRRule(schedule.RRule); err != nil {
		return nil, err
	}

	if err := validation.ValidateStringArray("exdates", schedule.ExDates, validation.MaxArraySize); err != nil {
		return nil, err
	}

	sanitizedNotes, err := validation.ValidateAndSanitizeNotes(schedule.Notes)
	if err != nil {
		return nil, err
	}
	schedule.Notes = sanitizedNotes

	// Default to UTC if timezone is empty
	if schedule.ScheduleTimezone == "" {
		schedule.ScheduleTimezone = "UTC"
	}

	schedule.UpdatedAt = time.Now().UTC()

	// Recalculate schedule_type based on rrule
	scheduleType := models.ScheduleTypeRecurring
	if strings.TrimSpace(schedule.RRule) == "" {
		scheduleType = models.ScheduleTypeOneShot
	}
	schedule.ScheduleType = scheduleType

	// Recalculate next_execution
	var nextExecution *time.Time
	if scheduleType == models.ScheduleTypeOneShot {
		// One-time event: next_execution is dtstart if in future and not yet executed
		if schedule.DTStart != nil && schedule.DTStart.After(time.Now()) && schedule.LastExecution == nil {
			nextExecution = schedule.DTStart
		}
	} else {
		// Recurring event: calculate from rrule
		if schedule.DTStart != nil {
			now := time.Now()
			if schedule.LastExecution != nil {
				now = *schedule.LastExecution
			}
			nextTime, err := calculateNextFromRRule(schedule.RRule, *schedule.DTStart, now)
			if err == nil && !nextTime.IsZero() {
				nextExecution = &nextTime
			}
		}
	}
	schedule.NextExecution = nextExecution

	query := `
		UPDATE schedules
		SET name = ?, rrule = ?, schedule_timezone = ?, dtstart = ?, exdates = ?, schedule_type = ?, next_execution = ?, notes = ?, enabled = ?, updated_at = ?
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

	var nextExecStr sql.NullString
	if nextExecution != nil {
		nextExecStr.Valid = true
		nextExecStr.String = nextExecution.Format(time.RFC3339)
	}

	_, err = db.Exec(query,
		schedule.Name,
		schedule.RRule,
		schedule.ScheduleTimezone,
		dtStartStr,
		exdatesStr,
		string(scheduleType),
		nextExecStr,
		schedule.Notes,
		schedule.Enabled,
		schedule.UpdatedAt.UTC().Format(time.RFC3339),
		schedule.ScheduleID,
	)

	if err != nil {
		return nil, err
	}

	return schedule, nil
}

// DeleteSchedule deletes a schedule (CASCADE DELETE will handle schedule_actions cleanup)
func (db *DB) DeleteSchedule(scheduleID string) error {
	// CASCADE DELETE on schedule_actions FK will automatically clean up join table entries
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
	_, err := db.Exec(query, enabled, time.Now().UTC().Format(time.RFC3339), scheduleID)
	return err
}

// UpdateLastExecution updates the last execution time for a schedule
// DEPRECATED: Use UpdateScheduleExecution instead for atomic updates
func (db *DB) UpdateLastExecution(scheduleID string, executionTime time.Time) error {
	query := `
		UPDATE schedules
		SET last_execution = ?, updated_at = ?
		WHERE schedule_id = ?
	`

	_, err := db.Exec(query,
		executionTime.UTC().Format(time.RFC3339),
		time.Now().UTC().Format(time.RFC3339),
		scheduleID,
	)
	return err
}

// UpdateScheduleExecution atomically updates last_execution and calculates/stores next_execution.
// This prevents race conditions by updating both fields in a single transaction.
func (db *DB) UpdateScheduleExecution(scheduleID string, scheduleType models.ScheduleType, rrule string, dtstart time.Time) error {
	// Begin transaction for atomic update
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	now := time.Now()
	var nextExecStr sql.NullString

	// Calculate next execution based on schedule type
	if scheduleType == models.ScheduleTypeRecurring {
		nextTime, err := calculateNextFromRRule(rrule, dtstart, now)
		if err == nil && !nextTime.IsZero() {
			nextExecStr.Valid = true
			nextExecStr.String = nextTime.Format(time.RFC3339)
		}
		// If error or zero time, nextExecStr remains NULL (no more occurrences)
	}
	// For ONE_SHOT, nextExecStr remains NULL (no next execution after first run)

	query := `
		UPDATE schedules
		SET last_execution = ?,
		    next_execution = ?,
		    updated_at = ?
		WHERE schedule_id = ?
	`

	_, err = tx.Exec(query,
		now.UTC().Format(time.RFC3339),
		nextExecStr,
		now.UTC().Format(time.RFC3339),
		scheduleID,
	)
	if err != nil {
		return fmt.Errorf("failed to update schedule execution: %w", err)
	}

	// Commit transaction
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	return nil
}

// GetActiveSchedules retrieves all enabled schedules
func (db *DB) GetActiveSchedules() ([]*models.Schedule, error) {
	query := `
		SELECT s.schedule_id, s.profile_id, s.routine_id, s.schedule_type, s.name, s.rrule, s.schedule_timezone,
		       s.dtstart, s.exdates, s.last_execution, s.next_execution, s.notes, s.enabled, s.created_at, s.updated_at
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
		var scheduleType string
		var dtstart, lastExecution, nextExecution, exdatesStr sql.NullString
		var createdAt, updatedAt string

		err := rows.Scan(
			&schedule.ScheduleID,
			&schedule.ProfileID,
			&schedule.RoutineID,
			&scheduleType,
			&schedule.Name,
			&schedule.RRule,
			&schedule.ScheduleTimezone,
			&dtstart,
			&exdatesStr,
			&lastExecution,
			&nextExecution,
			&schedule.Notes,
			&schedule.Enabled,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		// Convert schedule type string to enum
		schedule.ScheduleType = models.ScheduleType(scheduleType)

		if dtstart.Valid {
			t, parseErr := time.Parse(time.RFC3339, dtstart.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse dtstart for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.DTStart = &t
		}

		if lastExecution.Valid {
			t, parseErr := time.Parse(time.RFC3339, lastExecution.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse last_execution for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.LastExecution = &t
		}

		if nextExecution.Valid {
			t, parseErr := time.Parse(time.RFC3339, nextExecution.String)
			if parseErr != nil {
				return nil, fmt.Errorf("failed to parse next_execution for schedule %s: %w", schedule.ScheduleID, parseErr)
			}
			schedule.NextExecution = &t
		}

		if exdatesStr.Valid && exdatesStr.String != "" {
			schedule.ExDates = strings.Split(exdatesStr.String, ",")
		}

		var parseErr error
		schedule.CreatedAt, parseErr = time.Parse(time.RFC3339, createdAt)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse created_at for schedule %s: %w", schedule.ScheduleID, parseErr)
		}

		schedule.UpdatedAt, parseErr = time.Parse(time.RFC3339, updatedAt)
		if parseErr != nil {
			return nil, fmt.Errorf("failed to parse updated_at for schedule %s: %w", schedule.ScheduleID, parseErr)
		}

		schedules = append(schedules, &schedule)
	}

	return schedules, nil
}
