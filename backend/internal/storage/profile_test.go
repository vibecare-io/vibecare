package storage

import (
	"os"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// setupTestDB creates a temporary test database and returns the DB and path
func setupTestDB(t *testing.T) (*DB, string) {
	// Create temporary database
	dbPath := t.TempDir() + "/test.db"

	db, err := New(dbPath)
	if err != nil {
		t.Fatalf("Failed to create test database: %v", err)
	}

	return db, dbPath
}

// TestCreateProfileWithTimezone tests profile creation with timezone
func TestCreateProfileWithTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	tests := []struct {
		name             string
		profileName      string
		email            string
		timezone         string
		expectedTimezone string
	}{
		{
			name:             "Profile with America/Los_Angeles timezone",
			profileName:      "John Doe",
			email:            "john@example.com",
			timezone:         "America/Los_Angeles",
			expectedTimezone: "America/Los_Angeles",
		},
		{
			name:             "Profile with Asia/Tokyo timezone",
			profileName:      "Jane Smith",
			email:            "jane@example.com",
			timezone:         "Asia/Tokyo",
			expectedTimezone: "Asia/Tokyo",
		},
		{
			name:             "Profile with empty timezone defaults to UTC",
			profileName:      "Bob Johnson",
			email:            "bob@example.com",
			timezone:         "",
			expectedTimezone: "UTC",
		},
		{
			name:             "Profile with Europe/London timezone",
			profileName:      "Alice Brown",
			email:            "alice@example.com",
			timezone:         "Europe/London",
			expectedTimezone: "Europe/London",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			profile, err := db.CreateProfile(tt.profileName, tt.email, tt.timezone, map[string]string{})
			if err != nil {
				t.Fatalf("CreateProfile failed: %v", err)
			}

			if profile.Timezone != tt.expectedTimezone {
				t.Errorf("Expected timezone %s, got %s", tt.expectedTimezone, profile.Timezone)
			}

			// Verify profile was created in database
			retrieved, err := db.GetProfile(profile.ID)
			if err != nil {
				t.Fatalf("GetProfile failed: %v", err)
			}

			if retrieved.Timezone != tt.expectedTimezone {
				t.Errorf("Retrieved profile timezone %s, expected %s", retrieved.Timezone, tt.expectedTimezone)
			}
		})
	}
}

// TestUpdateProfileTimezone tests updating profile timezone
func TestUpdateProfileTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create initial profile
	profile, err := db.CreateProfile("Test User", "test@example.com", "America/New_York", map[string]string{})
	if err != nil {
		t.Fatalf("CreateProfile failed: %v", err)
	}

	if profile.Timezone != "America/New_York" {
		t.Errorf("Initial timezone should be America/New_York, got %s", profile.Timezone)
	}

	// Update timezone to Tokyo
	updated, err := db.UpdateProfile(profile.ID, "Test User", "test@example.com", "Asia/Tokyo", map[string]string{})
	if err != nil {
		t.Fatalf("UpdateProfile failed: %v", err)
	}

	if updated.Timezone != "Asia/Tokyo" {
		t.Errorf("Updated timezone should be Asia/Tokyo, got %s", updated.Timezone)
	}

	// Verify update persisted
	retrieved, err := db.GetProfile(profile.ID)
	if err != nil {
		t.Fatalf("GetProfile failed: %v", err)
	}

	if retrieved.Timezone != "Asia/Tokyo" {
		t.Errorf("Retrieved timezone should be Asia/Tokyo, got %s", retrieved.Timezone)
	}
}

// TestListProfilesWithTimezone tests listing profiles includes timezone
func TestListProfilesWithTimezone(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create multiple profiles with different timezones
	timezones := []string{"America/Los_Angeles", "Europe/Paris", "Asia/Singapore"}

	for i, tz := range timezones {
		name := "User" + string(rune('A'+i))
		email := "user" + string(rune('a'+i)) + "@example.com"
		_, err := db.CreateProfile(name, email, tz, map[string]string{})
		if err != nil {
			t.Fatalf("CreateProfile failed for %s: %v", name, err)
		}
	}

	// List all profiles
	profiles, err := db.ListProfiles()
	if err != nil {
		t.Fatalf("ListProfiles failed: %v", err)
	}

	if len(profiles) != 3 {
		t.Fatalf("Expected 3 profiles, got %d", len(profiles))
	}

	// Verify all profiles have correct timezones
	foundTimezones := make(map[string]bool)
	for _, profile := range profiles {
		if profile.Timezone == "" {
			t.Errorf("Profile %s has empty timezone", profile.Name)
		}
		foundTimezones[profile.Timezone] = true
	}

	for _, tz := range timezones {
		if !foundTimezones[tz] {
			t.Errorf("Expected to find timezone %s in results", tz)
		}
	}
}

// TestProfileTimezoneValidation tests timezone field handling
func TestProfileTimezoneValidation(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	tests := []struct {
		name          string
		email         string
		timezone      string
		shouldDefault bool
		expectedValue string
	}{
		{
			name:          "Valid IANA timezone",
			email:         "test1@example.com",
			timezone:      "America/Chicago",
			shouldDefault: false,
			expectedValue: "America/Chicago",
		},
		{
			name:          "Empty string defaults to UTC",
			email:         "test2@example.com",
			timezone:      "",
			shouldDefault: true,
			expectedValue: "UTC",
		},
		{
			name:          "UTC explicitly set",
			email:         "test3@example.com",
			timezone:      "UTC",
			shouldDefault: false,
			expectedValue: "UTC",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			profile, err := db.CreateProfile("Test", tt.email, tt.timezone, map[string]string{})
			if err != nil {
				t.Fatalf("CreateProfile failed: %v", err)
			}

			if profile.Timezone != tt.expectedValue {
				t.Errorf("Expected timezone %s, got %s", tt.expectedValue, profile.Timezone)
			}
		})
	}
}

// TestProfileTimezonePreservesOtherFields tests that timezone updates don't affect other fields
func TestProfileTimezonePreservesOtherFields(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	// Create profile with preferences
	prefs := map[string]string{"theme": "dark", "notifications": "enabled"}
	profile, err := db.CreateProfile("Test User", "test@example.com", "UTC", prefs)
	if err != nil {
		t.Fatalf("CreateProfile failed: %v", err)
	}

	originalCreatedAt := profile.CreatedAt
	originalUpdatedAt := profile.UpdatedAt
	time.Sleep(1100 * time.Millisecond) // Ensure timestamps differ (SQLite uses second precision)

	// Update only timezone
	updated, err := db.UpdateProfile(profile.ID, "Test User", "test@example.com", "America/New_York", prefs)
	if err != nil {
		t.Fatalf("UpdateProfile failed: %v", err)
	}

	// Verify timezone changed
	if updated.Timezone != "America/New_York" {
		t.Errorf("Timezone should be America/New_York, got %s", updated.Timezone)
	}

	// Verify other fields preserved
	if updated.Name != "Test User" {
		t.Errorf("Name should be preserved, got %s", updated.Name)
	}
	if updated.Email != "test@example.com" {
		t.Errorf("Email should be preserved, got %s", updated.Email)
	}
	if len(updated.Preferences) != 2 {
		t.Errorf("Preferences should be preserved, got %d entries", len(updated.Preferences))
	}

	// CreatedAt should not change (compare at second precision since SQLite TEXT doesn't store subseconds)
	if !updated.CreatedAt.Truncate(time.Second).Equal(originalCreatedAt.Truncate(time.Second)) {
		t.Errorf("CreatedAt should not change on update: original=%v, updated=%v", originalCreatedAt, updated.CreatedAt)
	}

	// UpdatedAt should change (compare at second precision)
	if !updated.UpdatedAt.Truncate(time.Second).After(originalUpdatedAt.Truncate(time.Second)) {
		t.Errorf("UpdatedAt should be after original UpdatedAt: original=%v, updated=%v", originalUpdatedAt, updated.UpdatedAt)
	}
}
