package models

import (
	"encoding/json"
	"time"
)

// Profile represents a user profile
type Profile struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Email       string            `json:"email"`
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

// Routine represents a routine with actions
type Routine struct {
	ID             string            `json:"id"`
	ProfileID      string            `json:"profile_id"`
	Name           string            `json:"name"`
	Description    string            `json:"description"`
	ActionIDs      []string          `json:"action_ids"`
	Enabled        bool              `json:"enabled"`
	Metadata       map[string]string `json:"metadata"`
	CreatedAt      time.Time         `json:"created_at"`
	UpdatedAt      time.Time         `json:"updated_at"`
	LastExecutedAt *time.Time        `json:"last_executed_at,omitempty"`
}

// Schedule represents a schedule for a routine
type Schedule struct {
	ScheduleID     string     `json:"schedule_id"` // UUID for local-first architecture
	RoutineID      string     `json:"routine_id"`
	Name           string     `json:"name"`
	RecurrenceJSON string     `json:"recurrence_json"` // RRule JSON
	DTStart        *time.Time `json:"dtstart,omitempty"`
	ExDates        []string   `json:"exdates,omitempty"`
	LastExecution  *time.Time `json:"last_execution,omitempty"`
	Notes          string     `json:"notes"`
	Enabled        bool       `json:"enabled"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

// RRule represents the recurrence rule
type RRule struct {
	Freq       string     `json:"freq"`       // YEARLY, MONTHLY, WEEKLY, DAILY, HOURLY, MINUTELY
	Interval   int        `json:"interval"`   // e.g., every 2 days
	ByHour     []int      `json:"byhour"`     // hours (0-23)
	ByMinute   []int      `json:"byminute"`   // minutes (0-59)
	ByDay      []string   `json:"byday"`      // MO, TU, WE, TH, FR, SA, SU
	ByMonthDay []int      `json:"bymonthday"` // day of month (1-31)
	ByMonth    []int      `json:"bymonth"`    // month (1-12)
	Until      *time.Time `json:"until"`      // End date
	Count      *int       `json:"count"`      // Number of occurrences
	ByWeekNo   []int      `json:"byweekno"`   // Week number
	ByYearDay  []int      `json:"byyearday"`  // Day of year
	WkSt       string     `json:"wkst"`       // Week start day (MO, TU, etc.)
}

// ExecutionLog represents an execution log entry
type ExecutionLog struct {
	LogID         int64             `json:"log_id"`
	RoutineID     string            `json:"routine_id"`
	Timestamp     time.Time         `json:"timestamp"`
	Completed     bool              `json:"completed"`
	Notes         string            `json:"notes"`
	ActionResults map[string]string `json:"action_results,omitempty"`
}

// ParseRRule parses RRule JSON string into RRule struct
func ParseRRule(jsonStr string) (*RRule, error) {
	var rrule RRule
	if err := json.Unmarshal([]byte(jsonStr), &rrule); err != nil {
		return nil, err
	}
	return &rrule, nil
}

// ToJSON converts RRule to JSON string
func (r *RRule) ToJSON() (string, error) {
	data, err := json.Marshal(r)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
