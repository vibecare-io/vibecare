package storage

import (
	"encoding/json"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// AddActionToSchedule adds an action to a schedule with the specified order
func (db *DB) AddActionToSchedule(scheduleID, actionID string, actionOrder int) error {
	query := `
		INSERT INTO schedule_actions (schedule_id, action_id, action_order)
		VALUES (?, ?, ?)
	`
	_, err := db.Exec(query, scheduleID, actionID, actionOrder)
	return err
}

// RemoveActionFromSchedule removes an action from a schedule
func (db *DB) RemoveActionFromSchedule(scheduleID, actionID string) error {
	query := `DELETE FROM schedule_actions WHERE schedule_id = ? AND action_id = ?`
	_, err := db.Exec(query, scheduleID, actionID)
	return err
}

// GetScheduleActions retrieves all actions for a schedule, ordered by action_order
func (db *DB) GetScheduleActions(scheduleID string) ([]*models.Action, error) {
	query := `
		SELECT a.action_id, a.profile_id, a.type, a.name, a.description, a.parameters, a.created_at, a.enabled
		FROM actions a
		INNER JOIN schedule_actions sa ON a.action_id = sa.action_id
		WHERE sa.schedule_id = ?
		ORDER BY sa.action_order
	`

	rows, err := db.Query(query, scheduleID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var actions []*models.Action
	for rows.Next() {
		var action models.Action
		var parametersJSON string
		var createdAtStr string

		err := rows.Scan(
			&action.ID,
			&action.ProfileID,
			&action.Type,
			&action.Name,
			&action.Description,
			&parametersJSON,
			&createdAtStr,
			&action.Enabled,
		)
		if err != nil {
			return nil, err
		}

		// Parse parameters JSON
		if parametersJSON != "" && parametersJSON != "{}" {
			if err := json.Unmarshal([]byte(parametersJSON), &action.Parameters); err != nil {
				return nil, err
			}
		} else {
			action.Parameters = make(map[string]string)
		}

		// Parse created_at timestamp
		if action.CreatedAt, err = time.Parse(time.RFC3339, createdAtStr); err != nil {
			return nil, err
		}

		actions = append(actions, &action)
	}

	return actions, nil
}

// UpdateScheduleActionOrder updates the order of an action within a schedule
func (db *DB) UpdateScheduleActionOrder(scheduleID, actionID string, newOrder int) error {
	query := `
		UPDATE schedule_actions
		SET action_order = ?
		WHERE schedule_id = ? AND action_id = ?
	`
	_, err := db.Exec(query, newOrder, scheduleID, actionID)
	return err
}

// ReplaceScheduleActions replaces all actions for a schedule with a new ordered list
func (db *DB) ReplaceScheduleActions(scheduleID string, actionIDs []string) error {
	// Start transaction
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// Delete existing actions for this schedule
	_, err = tx.Exec(`DELETE FROM schedule_actions WHERE schedule_id = ?`, scheduleID)
	if err != nil {
		return err
	}

	// Insert new actions with order
	stmt, err := tx.Prepare(`INSERT INTO schedule_actions (schedule_id, action_id, action_order) VALUES (?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for i, actionID := range actionIDs {
		_, err = stmt.Exec(scheduleID, actionID, i)
		if err != nil {
			return err
		}
	}

	return tx.Commit()
}
