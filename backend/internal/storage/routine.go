package storage

import (
	"database/sql"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateRoutine creates a new routine
func (db *DB) CreateRoutine(profileID, name, description string, actions []models.Action) (*models.Routine, error) {
	routine := &models.Routine{
		ID:          uuid.New().String(),
		ProfileID:   profileID,
		Name:        name,
		Description: description,
		Enabled:     true,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}

	// Store actions inline as JSON
	actionsJSON, _ := json.Marshal(actions)

	query := `
		INSERT INTO routines (id, profile_id, name, description, actions_json, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(query,
		routine.ID,
		routine.ProfileID,
		routine.Name,
		routine.Description,
		string(actionsJSON),
		routine.Enabled,
		routine.CreatedAt.Format(time.RFC3339),
		routine.UpdatedAt.Format(time.RFC3339),
	)

	if err != nil {
		return nil, err
	}

	return routine, nil
}

// GetRoutine retrieves a routine by ID
func (db *DB) GetRoutine(id string) (*models.Routine, error) {
	query := `
		SELECT id, profile_id, name, description, actions_json, enabled, created_at, updated_at
		FROM routines
		WHERE id = ?
	`

	var routine models.Routine
	var actionsJSON string
	var createdAt, updatedAt string

	err := db.QueryRow(query, id).Scan(
		&routine.ID,
		&routine.ProfileID,
		&routine.Name,
		&routine.Description,
		&actionsJSON,
		&routine.Enabled,
		&createdAt,
		&updatedAt,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	// Parse actions JSON into action IDs (for now we'll handle this later)
	// json.Unmarshal([]byte(actionsJSON), &routine.ActionIDs)
	routine.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	routine.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &routine, nil
}

// ListRoutines lists routines for a profile
func (db *DB) ListRoutines(profileID string, enabledOnly bool) ([]*models.Routine, error) {
	query := `
		SELECT id, profile_id, name, description, actions_json, enabled, created_at, updated_at
		FROM routines
		WHERE profile_id = ?
	`

	args := []interface{}{profileID}
	if enabledOnly {
		query += " AND enabled = ?"
		args = append(args, true)
	}

	query += " ORDER BY created_at DESC"

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var routines []*models.Routine
	for rows.Next() {
		var routine models.Routine
		var actionsJSON string
		var createdAt, updatedAt string

		err := rows.Scan(
			&routine.ID,
			&routine.ProfileID,
			&routine.Name,
			&routine.Description,
			&actionsJSON,
			&routine.Enabled,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		routine.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		routine.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

		routines = append(routines, &routine)
	}

	return routines, nil
}

// UpdateRoutineEnabled enables or disables a routine
func (db *DB) UpdateRoutineEnabled(id string, enabled bool) error {
	query := `
		UPDATE routines
		SET enabled = ?, updated_at = ?
		WHERE id = ?
	`

	_, err := db.Exec(query, enabled, time.Now().Format(time.RFC3339), id)
	return err
}