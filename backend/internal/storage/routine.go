package storage

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateRoutine creates a new routine with optional client-provided ID (with security checks)
func (db *DB) CreateRoutine(id, profileID, name, description string, actionIds []string, enabled bool, metadata map[string]string) (*models.Routine, error) {
	// Determine routine ID with security validation
	var routineID string

	if id != "" {
		// Client provided an ID - validate it

		// 1. Check ID format (must be valid UUID)
		if _, err := uuid.Parse(id); err != nil {
			return nil, fmt.Errorf("invalid routine ID format: %v", err)
		}

		// 2. Check for ID collision (CRITICAL SECURITY CHECK)
		existing, err := db.GetRoutine(id)
		if err != nil && err != sql.ErrNoRows {
			return nil, fmt.Errorf("failed to check for existing routine: %v", err)
		}
		if existing != nil {
			// ID already exists - reject to prevent overwrite attacks
			return nil, fmt.Errorf("routine with ID %s already exists", id)
		}

		routineID = id
	} else {
		// No client ID provided - generate server-side UUID
		routineID = uuid.New().String()
	}

	routine := &models.Routine{
		ID:          routineID,
		ProfileID:   profileID,
		Name:        name,
		Description: description,
		ActionIDs:   actionIds,
		Enabled:     enabled,
		Metadata:    metadata,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}

	// Store action IDs and metadata as JSON
	actionIdsJSON, _ := json.Marshal(actionIds)
	metadataJSON, _ := json.Marshal(metadata)

	query := `
		INSERT INTO routines (id, profile_id, name, description, action_ids, metadata, enabled, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(query,
		routine.ID,
		routine.ProfileID,
		routine.Name,
		routine.Description,
		string(actionIdsJSON),
		string(metadataJSON),
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
		SELECT id, profile_id, name, description, action_ids, metadata, enabled,
		       created_at, updated_at, last_executed_at
		FROM routines
		WHERE id = ?
	`

	var routine models.Routine
	var actionIdsJSON, metadataJSON string
	var createdAt, updatedAt string
	var lastExecutedAt sql.NullString

	err := db.QueryRow(query, id).Scan(
		&routine.ID,
		&routine.ProfileID,
		&routine.Name,
		&routine.Description,
		&actionIdsJSON,
		&metadataJSON,
		&routine.Enabled,
		&createdAt,
		&updatedAt,
		&lastExecutedAt,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	// Parse JSON fields
	json.Unmarshal([]byte(actionIdsJSON), &routine.ActionIDs)
	json.Unmarshal([]byte(metadataJSON), &routine.Metadata)

	routine.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	routine.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	if lastExecutedAt.Valid {
		t, _ := time.Parse(time.RFC3339, lastExecutedAt.String)
		routine.LastExecutedAt = &t
	}

	return &routine, nil
}

// ListRoutines lists routines for a profile
func (db *DB) ListRoutines(profileID string, enabledOnly bool) ([]*models.Routine, error) {
	query := `
		SELECT id, profile_id, name, description, action_ids, metadata, enabled,
		       created_at, updated_at, last_executed_at
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
		var actionIdsJSON, metadataJSON string
		var createdAt, updatedAt string
		var lastExecutedAt sql.NullString

		err := rows.Scan(
			&routine.ID,
			&routine.ProfileID,
			&routine.Name,
			&routine.Description,
			&actionIdsJSON,
			&metadataJSON,
			&routine.Enabled,
			&createdAt,
			&updatedAt,
			&lastExecutedAt,
		)
		if err != nil {
			return nil, err
		}

		// Parse JSON fields
		json.Unmarshal([]byte(actionIdsJSON), &routine.ActionIDs)
		json.Unmarshal([]byte(metadataJSON), &routine.Metadata)

		routine.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		routine.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

		if lastExecutedAt.Valid {
			t, _ := time.Parse(time.RFC3339, lastExecutedAt.String)
			routine.LastExecutedAt = &t
		}

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

// UpdateRoutine updates a routine with new information
func (db *DB) UpdateRoutine(routine *models.Routine) (*models.Routine, error) {
	routine.UpdatedAt = time.Now()

	actionIdsJSON, _ := json.Marshal(routine.ActionIDs)
	metadataJSON, _ := json.Marshal(routine.Metadata)

	query := `
		UPDATE routines
		SET name = ?, description = ?, action_ids = ?, metadata = ?, enabled = ?, updated_at = ?
		WHERE id = ?
	`

	_, err := db.Exec(query,
		routine.Name,
		routine.Description,
		string(actionIdsJSON),
		string(metadataJSON),
		routine.Enabled,
		routine.UpdatedAt.Format(time.RFC3339),
		routine.ID,
	)

	if err != nil {
		return nil, err
	}

	return routine, nil
}

// DeleteRoutine deletes a routine by ID
func (db *DB) DeleteRoutine(id string) error {
	query := `DELETE FROM routines WHERE id = ?`
	_, err := db.Exec(query, id)
	return err
}

// UpdateRoutineLastExecuted updates the last executed time for a routine
func (db *DB) UpdateRoutineLastExecuted(id string) error {
	query := `
		UPDATE routines
		SET last_executed_at = ?, updated_at = ?
		WHERE id = ?
	`

	now := time.Now()
	_, err := db.Exec(query, now.Format(time.RFC3339), now.Format(time.RFC3339), id)
	return err
}
