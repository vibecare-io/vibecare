package models

import (
	"time"
)

// Profile represents a user profile
type Profile struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Email       string            `json:"email"`
	Timezone    string            `json:"timezone"` // IANA timezone (e.g., "America/Los_Angeles")
	Preferences map[string]string `json:"preferences"`
	Devices     []Device          `json:"devices"`
	CreatedAt   time.Time         `json:"created_at"`
	UpdatedAt   time.Time         `json:"updated_at"`
}

// Device represents a user's device
type Device struct {
	ID        string    `json:"id"`
	ProfileID string    `json:"profile_id"`
	Name      string    `json:"name"`
	Type      string    `json:"type"`
	PushToken string    `json:"push_token"`
	LastSeen  time.Time `json:"last_seen"`
	Active    bool      `json:"active"`
}

// Action represents an action that can be executed
type Action struct {
	ID          string            `json:"id"`
	ProfileID   string            `json:"profile_id"`
	Type        ActionType        `json:"type"`
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Parameters  map[string]string `json:"parameters"`
	CreatedAt   time.Time         `json:"created_at"`
	Enabled     bool              `json:"enabled"`
}

// ActionType enum
type ActionType string

const (
	ActionTypeNotification  ActionType = "notification"
	ActionTypeOpenLink      ActionType = "open_link"
	ActionTypeSendEmail     ActionType = "send_email"
	ActionTypeRunScript     ActionType = "run_script"
	ActionTypePlaySound     ActionType = "play_sound"
	ActionTypeSystemCommand ActionType = "system_command"
	ActionTypeAPICall       ActionType = "api_call"
	ActionTypeLogEntry      ActionType = "log_entry"
)

// Routine represents a routine (metadata/grouping only, no direct action links)
type Routine struct {
	ID             string            `json:"id"`
	ProfileID      string            `json:"profile_id"`
	Name           string            `json:"name"`
	Description    string            `json:"description"`
	Enabled        bool              `json:"enabled"`
	Metadata       map[string]string `json:"metadata"`
	CreatedAt      time.Time         `json:"created_at"`
	UpdatedAt      time.Time         `json:"updated_at"`
	LastExecutedAt *time.Time        `json:"last_executed_at,omitempty"`
}

// ScheduleType defines the type of schedule (one-time or recurring)
type ScheduleType string

const (
	ScheduleTypeOneShot   ScheduleType = "ONE_SHOT"
	ScheduleTypeRecurring ScheduleType = "RECURRING"
)

// Schedule represents a schedule for a routine
type Schedule struct {
	ScheduleID       string       `json:"schedule_id"` // UUID for local-first architecture
	ProfileID        string       `json:"profile_id"`
	RoutineID        string       `json:"routine_id"`
	ScheduleType     ScheduleType `json:"schedule_type"` // ONE_SHOT or RECURRING
	Name             string       `json:"name"`
	RRule            string       `json:"rrule"`             // RFC 5545 RRule string (empty for ONE_SHOT)
	ScheduleTimezone string       `json:"schedule_timezone"` // IANA timezone for RRule calculations
	DTStart          *time.Time   `json:"dtstart,omitempty"`
	ExDates          []string     `json:"exdates,omitempty"`
	LastExecution    *time.Time   `json:"last_execution,omitempty"`
	NextExecution    *time.Time   `json:"next_execution,omitempty"` // Pre-calculated for performance
	Notes            string       `json:"notes"`
	Enabled          bool         `json:"enabled"`
	CreatedAt        time.Time    `json:"created_at"`
	UpdatedAt        time.Time    `json:"updated_at"`

	// Join fields (not stored in DB, populated from joins)
	RoutineName string `json:"routine_name,omitempty"`
	ProfileName string `json:"profile_name,omitempty"`
}

// ScheduleAction represents the join table between schedules and actions
type ScheduleAction struct {
	ScheduleID  string `json:"schedule_id"`
	ActionID    string `json:"action_id"`
	ActionOrder int    `json:"action_order"`
}
