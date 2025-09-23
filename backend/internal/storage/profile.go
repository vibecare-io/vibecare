package storage

import (
	"database/sql"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/models"
)

// CreateProfile creates a new profile
func (db *DB) CreateProfile(name, email string, preferences map[string]string) (*models.Profile, error) {
	profile := &models.Profile{
		ID:          uuid.New().String(),
		Name:        name,
		Email:       email,
		Preferences: preferences,
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
	}

	prefsJSON, _ := json.Marshal(preferences)

	query := `
		INSERT INTO profiles (id, name, email, preferences_json, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(query,
		profile.ID,
		profile.Name,
		profile.Email,
		string(prefsJSON),
		profile.CreatedAt.Format(time.RFC3339),
		profile.UpdatedAt.Format(time.RFC3339),
	)

	if err != nil {
		return nil, err
	}

	return profile, nil
}

// GetProfile retrieves a profile by ID
func (db *DB) GetProfile(id string) (*models.Profile, error) {
	query := `
		SELECT id, name, email, preferences_json, created_at, updated_at
		FROM profiles
		WHERE id = ?
	`

	var profile models.Profile
	var prefsJSON string
	var createdAt, updatedAt string

	err := db.QueryRow(query, id).Scan(
		&profile.ID,
		&profile.Name,
		&profile.Email,
		&prefsJSON,
		&createdAt,
		&updatedAt,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	json.Unmarshal([]byte(prefsJSON), &profile.Preferences)
	profile.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	profile.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &profile, nil
}

// GetProfileByEmail retrieves a profile by email
func (db *DB) GetProfileByEmail(email string) (*models.Profile, error) {
	query := `
		SELECT id, name, email, preferences_json, created_at, updated_at
		FROM profiles
		WHERE email = ?
	`

	var profile models.Profile
	var prefsJSON string
	var createdAt, updatedAt string

	err := db.QueryRow(query, email).Scan(
		&profile.ID,
		&profile.Name,
		&profile.Email,
		&prefsJSON,
		&createdAt,
		&updatedAt,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	json.Unmarshal([]byte(prefsJSON), &profile.Preferences)
	profile.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	profile.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &profile, nil
}

// ListProfiles lists all profiles
func (db *DB) ListProfiles() ([]*models.Profile, error) {
	query := `
		SELECT id, name, email, preferences_json, created_at, updated_at
		FROM profiles
		ORDER BY created_at DESC
	`

	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var profiles []*models.Profile
	for rows.Next() {
		var profile models.Profile
		var prefsJSON string
		var createdAt, updatedAt string

		err := rows.Scan(
			&profile.ID,
			&profile.Name,
			&profile.Email,
			&prefsJSON,
			&createdAt,
			&updatedAt,
		)
		if err != nil {
			return nil, err
		}

		json.Unmarshal([]byte(prefsJSON), &profile.Preferences)
		profile.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
		profile.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

		profiles = append(profiles, &profile)
	}

	return profiles, nil
}