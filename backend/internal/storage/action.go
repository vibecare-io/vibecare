package storage

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateAction creates a new action in the database
func (db *DB) CreateAction(action *models.Action) error {
	parametersJSON, err := json.Marshal(action.Parameters)
	if err != nil {
		return fmt.Errorf("failed to marshal parameters: %w", err)
	}

	query := `
		INSERT INTO actions (action_id, profile_id, type, name, description, parameters_json, created_at, enabled)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`

	_, err = db.Exec(query,
		action.ID,
		action.ProfileID,
		action.Type,
		action.Name,
		action.Description,
		string(parametersJSON),
		action.CreatedAt.Format(time.RFC3339),
		action.Enabled,
	)

	if err != nil {
		return fmt.Errorf("failed to create action: %w", err)
	}

	return nil
}

// GetAction retrieves an action by ID
func (db *DB) GetAction(actionID string) (*models.Action, error) {
	query := `
		SELECT action_id, profile_id, type, name, description, parameters_json, created_at, enabled
		FROM actions
		WHERE action_id = ?
	`

	var action models.Action
	var parametersJSON string
	var createdAtStr string

	err := db.QueryRow(query, actionID).Scan(
		&action.ID,
		&action.ProfileID,
		&action.Type,
		&action.Name,
		&action.Description,
		&parametersJSON,
		&createdAtStr,
		&action.Enabled,
	)

	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("action not found: %s", actionID)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get action: %w", err)
	}

	// Parse parameters JSON
	if parametersJSON != "" {
		if err := json.Unmarshal([]byte(parametersJSON), &action.Parameters); err != nil {
			return nil, fmt.Errorf("failed to unmarshal parameters: %w", err)
		}
	} else {
		action.Parameters = make(map[string]string)
	}

	// Parse created_at
	action.CreatedAt, _ = time.Parse(time.RFC3339, createdAtStr)

	return &action, nil
}

// GetActionsByIDs retrieves multiple actions by their IDs
func (db *DB) GetActionsByIDs(actionIDs []string) ([]*models.Action, error) {
	if len(actionIDs) == 0 {
		return []*models.Action{}, nil
	}

	actions := make([]*models.Action, 0, len(actionIDs))

	for _, actionID := range actionIDs {
		action, err := db.GetAction(actionID)
		if err != nil {
			// Log error but continue with other actions
			continue
		}
		actions = append(actions, action)
	}

	return actions, nil
}

// UpdateAction updates an existing action
func (db *DB) UpdateAction(action *models.Action) error {
	parametersJSON, err := json.Marshal(action.Parameters)
	if err != nil {
		return fmt.Errorf("failed to marshal parameters: %w", err)
	}

	query := `
		UPDATE actions
		SET type = ?, name = ?, description = ?, parameters_json = ?, enabled = ?
		WHERE action_id = ?
	`

	result, err := db.Exec(query,
		action.Type,
		action.Name,
		action.Description,
		string(parametersJSON),
		action.Enabled,
		action.ID,
	)

	if err != nil {
		return fmt.Errorf("failed to update action: %w", err)
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("failed to get rows affected: %w", err)
	}

	if rowsAffected == 0 {
		return fmt.Errorf("action not found: %s", action.ID)
	}

	return nil
}

// DeleteAction deletes an action by ID
func (db *DB) DeleteAction(actionID string) error {
	query := `DELETE FROM actions WHERE action_id = ?`

	result, err := db.Exec(query, actionID)
	if err != nil {
		return fmt.Errorf("failed to delete action: %w", err)
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("failed to get rows affected: %w", err)
	}

	if rowsAffected == 0 {
		return fmt.Errorf("action not found: %s", actionID)
	}

	return nil
}

// ListActionsByProfile retrieves all actions for a profile
func (db *DB) ListActionsByProfile(profileID string) ([]*models.Action, error) {
	query := `
		SELECT action_id, profile_id, type, name, description, parameters_json, created_at, enabled
		FROM actions
		WHERE profile_id = ?
		ORDER BY created_at DESC
	`

	rows, err := db.Query(query, profileID)
	if err != nil {
		return nil, fmt.Errorf("failed to list actions: %w", err)
	}
	defer rows.Close()

	actions := []*models.Action{}

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
			return nil, fmt.Errorf("failed to scan action: %w", err)
		}

		// Parse parameters JSON
		if parametersJSON != "" {
			if err := json.Unmarshal([]byte(parametersJSON), &action.Parameters); err != nil {
				return nil, fmt.Errorf("failed to unmarshal parameters: %w", err)
			}
		} else {
			action.Parameters = make(map[string]string)
		}

		// Parse created_at
		action.CreatedAt, _ = time.Parse(time.RFC3339, createdAtStr)

		actions = append(actions, &action)
	}

	return actions, nil
}

// ListActionsByType retrieves all actions of a specific type for a profile
func (db *DB) ListActionsByType(profileID string, actionType models.ActionType) ([]*models.Action, error) {
	query := `
		SELECT action_id, profile_id, type, name, description, parameters_json, created_at, enabled
		FROM actions
		WHERE profile_id = ? AND type = ?
		ORDER BY created_at DESC
	`

	rows, err := db.Query(query, profileID, actionType)
	if err != nil {
		return nil, fmt.Errorf("failed to list actions by type: %w", err)
	}
	defer rows.Close()

	actions := []*models.Action{}

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
			return nil, fmt.Errorf("failed to scan action: %w", err)
		}

		// Parse parameters JSON
		if parametersJSON != "" {
			if err := json.Unmarshal([]byte(parametersJSON), &action.Parameters); err != nil {
				return nil, fmt.Errorf("failed to unmarshal parameters: %w", err)
			}
		} else {
			action.Parameters = make(map[string]string)
		}

		// Parse created_at
		action.CreatedAt, _ = time.Parse(time.RFC3339, createdAtStr)

		actions = append(actions, &action)
	}

	return actions, nil
}
