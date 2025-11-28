package storage

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/teambition/rrule-go"
	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/validation"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

const (
	// rruleCalculationTimeout prevents runaway iterations for high-frequency rules
	rruleCalculationTimeout = 2 * time.Second
	// rruleSlowThreshold logs calculations slower than this
	rruleSlowThreshold = 100 * time.Millisecond
)

var rruleTracer = otel.Tracer("vibecare/storage/rrule")

// applyTimezoneToRRule fixes the timezone on a parsed RRule.
// rrule.StrToRRule() always defaults to UTC - this function sets the correct
// timezone Location on DTStart and recreates the rule so it respects the timezone.
func applyTimezoneToRRule(rule *rrule.RRule, dtstartWithTimezone time.Time) (*rrule.RRule, error) {
	rule.Options.Dtstart = dtstartWithTimezone
	return rrule.NewRRule(rule.Options)
}

// calculateNextFromRRule calculates the next execution time based on an RRule string.
// Returns zero time if the rrule is empty, invalid, or has no future occurrences.
// The scheduleTimezone parameter specifies the IANA timezone (e.g., "America/Chicago")
// in which the schedule was created - this ensures "9am CDT" triggers at 9am Central time.
func calculateNextFromRRule(rruleStr string, dtstart, after time.Time, scheduleTimezone string) (time.Time, error) {
	ctx, cancel := context.WithTimeout(context.Background(), rruleCalculationTimeout)
	defer cancel()
	return calculateNextFromRRuleWithContext(ctx, rruleStr, dtstart, after, scheduleTimezone)
}

// calculateNextFromRRuleWithContext calculates next execution with timeout and telemetry.
// The scheduleTimezone parameter specifies the IANA timezone for the schedule.
func calculateNextFromRRuleWithContext(ctx context.Context, rruleStr string, dtstart, after time.Time, scheduleTimezone string) (time.Time, error) {
	// Empty rrule means one-time event (no next execution)
	if strings.TrimSpace(rruleStr) == "" {
		return time.Time{}, fmt.Errorf("empty rrule")
	}

	// Load the schedule's timezone location
	// Default to UTC if timezone is empty or invalid
	loc := time.UTC
	if scheduleTimezone != "" {
		if loadedLoc, err := time.LoadLocation(scheduleTimezone); err == nil {
			loc = loadedLoc
		}
	}

	// Convert dtstart and after to the schedule's timezone
	// This ensures RRule calculations happen in the user's intended timezone
	dtstartInTZ := dtstart.In(loc)
	afterInTZ := after.In(loc)

	// Start telemetry span
	ctx, span := rruleTracer.Start(ctx, "calculateNextFromRRule",
		trace.WithAttributes(
			attribute.String("rrule.input", rruleStr),
			attribute.String("rrule.dtstart", dtstart.Format(time.RFC3339)),
			attribute.String("rrule.after", after.Format(time.RFC3339)),
			attribute.String("rrule.timezone", scheduleTimezone),
		),
	)
	defer span.End()

	startTime := time.Now()

	// Parse the RRule first to extract frequency and other options
	// Note: StrToRRule always defaults to UTC, so we'll fix the timezone after
	fullRRule := "DTSTART:" + dtstartInTZ.Format("20060102T150405Z") + "\nRRULE:" + rruleStr
	rule, err := rrule.StrToRRule(fullRRule)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "parse failed")
		return time.Time{}, fmt.Errorf("failed to parse rrule: %w", err)
	}

	// Check for problematic high-frequency rules with time constraints
	// These cause massive iteration counts and should be rejected
	freq := rule.Options.Freq
	opts := rule.Options
	if isProblematicRRule(freq, opts) {
		err := fmt.Errorf("problematic rrule: high-frequency (%s) with BYHOUR/BYMINUTE constraints causes excessive iteration", freqToString(freq))
		span.RecordError(err)
		span.SetStatus(codes.Error, "problematic rrule rejected")
		span.SetAttributes(attribute.Bool("rrule.rejected", true))
		fmt.Printf("[RRULE_REJECTED] rrule=%q freq=%s reason=high_freq_with_time_constraints\n", rruleStr, freqToString(freq))
		// Return dtstart as a fallback next execution
		return dtstart, nil
	}

	// Optimize dtstart for high-frequency rules to reduce iterations
	// Use timezone-aware values for optimization
	effectiveDtstart := optimizeDtstartForFrequency(freq, dtstartInTZ, afterInTZ, loc)

	span.SetAttributes(
		attribute.String("rrule.frequency", freqToString(freq)),
		attribute.String("rrule.effective_dtstart", effectiveDtstart.Format(time.RFC3339)),
		attribute.Bool("rrule.dtstart_optimized", !effectiveDtstart.Equal(dtstartInTZ)),
	)

	// Apply the correct timezone to the rule
	// effectiveDtstart already has the correct Location (e.g., America/Chicago)
	rule, err = applyTimezoneToRRule(rule, effectiveDtstart)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "failed to apply timezone to rule")
		return time.Time{}, fmt.Errorf("failed to apply timezone to rrule: %w", err)
	}

	// Create RSet and add the rule
	rset := &rrule.Set{}
	rset.RRule(rule)

	// Run After() in goroutine to support timeout
	type result struct {
		next time.Time
	}
	resultCh := make(chan result, 1)

	go func() {
		// Use timezone-aware 'after' for the comparison
		next := rset.After(afterInTZ, false)
		resultCh <- result{next: next}
	}()

	// Wait for result or timeout
	select {
	case <-ctx.Done():
		elapsed := time.Since(startTime)
		span.SetAttributes(
			attribute.Float64("rrule.duration_ms", float64(elapsed.Milliseconds())),
			attribute.Bool("rrule.timed_out", true),
		)
		span.RecordError(ctx.Err())
		span.SetStatus(codes.Error, "calculation timed out")

		// Log for investigation
		fmt.Printf("[RRULE_TIMEOUT] duration=%v rrule=%q freq=%s dtstart=%s effective_dtstart=%s after=%s\n",
			elapsed, rruleStr, freqToString(freq), dtstart.Format(time.RFC3339),
			effectiveDtstart.Format(time.RFC3339), after.Format(time.RFC3339))

		return time.Time{}, fmt.Errorf("rrule calculation timed out after %v", elapsed)

	case res := <-resultCh:
		elapsed := time.Since(startTime)
		span.SetAttributes(
			attribute.Float64("rrule.duration_ms", float64(elapsed.Milliseconds())),
			attribute.Bool("rrule.timed_out", false),
			attribute.String("rrule.next_execution", res.next.Format(time.RFC3339)),
		)

		// Log slow calculations
		if elapsed > rruleSlowThreshold {
			span.SetAttributes(attribute.Bool("rrule.slow", true))
			fmt.Printf("[RRULE_SLOW] duration=%v rrule=%q freq=%s dtstart=%s effective_dtstart=%s after=%s next=%s\n",
				elapsed, rruleStr, freqToString(freq), dtstart.Format(time.RFC3339),
				effectiveDtstart.Format(time.RFC3339), after.Format(time.RFC3339), res.next.Format(time.RFC3339))
		}

		span.SetStatus(codes.Ok, "")
		return res.next.UTC(), nil
	}
}

// isProblematicRRule detects RRule patterns that cause excessive CPU usage.
// High-frequency rules (MINUTELY, SECONDLY, HOURLY) with BYHOUR/BYMINUTE constraints
// force the library to iterate through many non-matching occurrences.
func isProblematicRRule(freq rrule.Frequency, opts rrule.ROption) bool {
	hasByHour := len(opts.Byhour) > 0
	hasByMinute := len(opts.Byminute) > 0

	switch freq {
	case rrule.SECONDLY:
		// SECONDLY with any hour/minute constraint is problematic
		return hasByHour || hasByMinute
	case rrule.MINUTELY:
		// MINUTELY with hour constraint is problematic (has to skip many minutes)
		return hasByHour
	case rrule.HOURLY:
		// HOURLY with specific hour constraint is problematic
		return hasByHour
	}
	return false
}

// optimizeDtstartForFrequency moves dtstart closer to 'after' for high-frequency rules.
// This dramatically reduces the number of iterations needed by rrule-go's After() method.
// The loc parameter specifies the timezone to use for the optimized time.
func optimizeDtstartForFrequency(freq rrule.Frequency, dtstart, after time.Time, loc *time.Location) time.Time {
	// Only optimize if dtstart is before 'after'
	if !dtstart.Before(after) {
		return dtstart
	}

	// Calculate safe lookback based on frequency
	// We go back enough to ensure we don't miss the pattern alignment
	var lookback time.Duration
	switch freq {
	case rrule.SECONDLY:
		lookback = 1 * time.Minute
	case rrule.MINUTELY:
		lookback = 1 * time.Hour
	case rrule.HOURLY:
		lookback = 24 * time.Hour
	case rrule.DAILY:
		lookback = 7 * 24 * time.Hour
	case rrule.WEEKLY:
		lookback = 4 * 7 * 24 * time.Hour
	case rrule.MONTHLY:
		lookback = 60 * 24 * time.Hour // ~2 months
	case rrule.YEARLY:
		lookback = 400 * 24 * time.Hour // ~13 months
	default:
		return dtstart
	}

	// Calculate candidate: go back from 'after' by lookback amount
	candidate := after.Add(-lookback)

	// Preserve time-of-day from original dtstart (important for patterns like "every day at 9am")
	// Use the provided timezone location for consistency
	candidate = time.Date(
		candidate.Year(), candidate.Month(), candidate.Day(),
		dtstart.Hour(), dtstart.Minute(), dtstart.Second(), dtstart.Nanosecond(),
		loc,
	)

	// Only use candidate if it's after original dtstart (don't go backwards)
	if candidate.After(dtstart) {
		return candidate
	}
	return dtstart
}

// freqToString converts rrule.Frequency to string for logging/telemetry
func freqToString(freq rrule.Frequency) string {
	switch freq {
	case rrule.YEARLY:
		return "YEARLY"
	case rrule.MONTHLY:
		return "MONTHLY"
	case rrule.WEEKLY:
		return "WEEKLY"
	case rrule.DAILY:
		return "DAILY"
	case rrule.HOURLY:
		return "HOURLY"
	case rrule.MINUTELY:
		return "MINUTELY"
	case rrule.SECONDLY:
		return "SECONDLY"
	default:
		return fmt.Sprintf("UNKNOWN(%d)", freq)
	}
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
		// For recurring events, calculate from rrule using the schedule's timezone
		if dtstart != nil {
			nextTime, err := calculateNextFromRRule(rrule, *dtstart, time.Now(), scheduleTimezone)
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
			nextTime, err := calculateNextFromRRule(schedule.RRule, *schedule.DTStart, now, schedule.ScheduleTimezone)
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
// The scheduleTimezone parameter specifies the IANA timezone for RRule calculations.
func (db *DB) UpdateScheduleExecution(scheduleID string, scheduleType models.ScheduleType, rrule string, dtstart time.Time, scheduleTimezone string) error {
	// Begin transaction for atomic update
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer tx.Rollback()

	now := time.Now()
	var nextExecStr sql.NullString

	// Calculate next execution based on schedule type, using the schedule's timezone
	if scheduleType == models.ScheduleTypeRecurring {
		nextTime, err := calculateNextFromRRule(rrule, dtstart, now, scheduleTimezone)
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
