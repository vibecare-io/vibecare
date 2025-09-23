package storage

import (
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateExecutionLog creates a new execution log entry
func (db *DB) CreateExecutionLog(routineID string, completed bool, notes string) (*models.ExecutionLog, error) {
	log := &models.ExecutionLog{
		RoutineID: routineID,
		Timestamp: time.Now(),
		Completed: completed,
		Notes:     notes,
	}

	query := `
		INSERT INTO execution_logs (routine_id, timestamp, completed, notes)
		VALUES (?, ?, ?, ?)
	`

	result, err := db.Exec(query,
		log.RoutineID,
		log.Timestamp.Format(time.RFC3339),
		log.Completed,
		log.Notes,
	)

	if err != nil {
		return nil, err
	}

	log.LogID, _ = result.LastInsertId()
	return log, nil
}

// GetExecutionLogs retrieves execution logs for a routine
func (db *DB) GetExecutionLogs(routineID string, limit int) ([]*models.ExecutionLog, error) {
	query := `
		SELECT log_id, routine_id, timestamp, completed, notes
		FROM execution_logs
		WHERE routine_id = ?
		ORDER BY timestamp DESC
		LIMIT ?
	`

	if limit <= 0 {
		limit = 100 // Default limit
	}

	rows, err := db.Query(query, routineID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var logs []*models.ExecutionLog
	for rows.Next() {
		var log models.ExecutionLog
		var timestamp string

		err := rows.Scan(
			&log.LogID,
			&log.RoutineID,
			&timestamp,
			&log.Completed,
			&log.Notes,
		)
		if err != nil {
			return nil, err
		}

		log.Timestamp, _ = time.Parse(time.RFC3339, timestamp)
		logs = append(logs, &log)
	}

	return logs, nil
}

// GetRecentExecutions retrieves recent execution logs across all routines
func (db *DB) GetRecentExecutions(profileID string, limit int) ([]*models.ExecutionLog, error) {
	query := `
		SELECT el.log_id, el.routine_id, el.timestamp, el.completed, el.notes
		FROM execution_logs el
		INNER JOIN routines r ON el.routine_id = r.id
		WHERE r.profile_id = ?
		ORDER BY el.timestamp DESC
		LIMIT ?
	`

	if limit <= 0 {
		limit = 50
	}

	rows, err := db.Query(query, profileID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var logs []*models.ExecutionLog
	for rows.Next() {
		var log models.ExecutionLog
		var timestamp string

		err := rows.Scan(
			&log.LogID,
			&log.RoutineID,
			&timestamp,
			&log.Completed,
			&log.Notes,
		)
		if err != nil {
			return nil, err
		}

		log.Timestamp, _ = time.Parse(time.RFC3339, timestamp)
		logs = append(logs, &log)
	}

	return logs, nil
}