package validation

import (
	"strings"
	"testing"
)

func TestValidateRRule(t *testing.T) {
	tests := []struct {
		name      string
		rrule     string
		wantError bool
		errorMsg  string
	}{
		{
			name:      "empty string is valid (one-time event)",
			rrule:     "",
			wantError: false,
		},
		{
			name:      "whitespace-only string is valid (one-time event)",
			rrule:     "   ",
			wantError: false,
		},
		{
			name:      "valid daily recurrence",
			rrule:     "FREQ=DAILY",
			wantError: false,
		},
		{
			name:      "valid daily recurrence with count",
			rrule:     "FREQ=DAILY;COUNT=5",
			wantError: false,
		},
		{
			name:      "valid weekly recurrence",
			rrule:     "FREQ=WEEKLY;BYDAY=MO,WE,FR",
			wantError: false,
		},
		{
			name:      "valid monthly recurrence",
			rrule:     "FREQ=MONTHLY;BYMONTHDAY=15",
			wantError: false,
		},
		{
			name:      "valid yearly recurrence",
			rrule:     "FREQ=YEARLY;BYMONTH=12;BYMONTHDAY=25",
			wantError: false,
		},
		{
			name:      "valid hourly recurrence with interval",
			rrule:     "FREQ=HOURLY;INTERVAL=2",
			wantError: false,
		},
		{
			name:      "valid minutely recurrence",
			rrule:     "FREQ=MINUTELY;INTERVAL=20",
			wantError: false,
		},
		{
			name:      "invalid format - missing FREQ",
			rrule:     "COUNT=5",
			wantError: true,
			errorMsg:  "invalid RFC 5545 format",
		},
		{
			name:      "invalid format - wrong frequency",
			rrule:     "FREQ=INVALID",
			wantError: true,
			errorMsg:  "invalid RFC 5545 format",
		},
		{
			name:      "invalid format - random text",
			rrule:     "INVALID_RRULE_FORMAT",
			wantError: true,
			errorMsg:  "invalid RFC 5545 format",
		},
		{
			name:      "invalid format - malformed syntax",
			rrule:     "FREQ=DAILY;INVALID",
			wantError: true,
			errorMsg:  "invalid RFC 5545 format",
		},
		{
			name:      "invalid format - empty after semicolon",
			rrule:     "FREQ=DAILY;",
			wantError: true,
			errorMsg:  "invalid RFC 5545 format",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateRRule(tt.rrule)

			if tt.wantError {
				if err == nil {
					t.Errorf("ValidateRRule(%q) expected error but got nil", tt.rrule)
					return
				}
				if tt.errorMsg != "" && !strings.Contains(err.Error(), tt.errorMsg) {
					t.Errorf("ValidateRRule(%q) error = %v, want error containing %q", tt.rrule, err, tt.errorMsg)
				}
				// Verify it's a ValidationError
				if _, ok := err.(*ValidationError); !ok {
					t.Errorf("ValidateRRule(%q) error type = %T, want *ValidationError", tt.rrule, err)
				}
			} else {
				if err != nil {
					t.Errorf("ValidateRRule(%q) unexpected error = %v", tt.rrule, err)
				}
			}
		})
	}
}

func TestValidateRRule_EdgeCases(t *testing.T) {
	tests := []struct {
		name      string
		rrule     string
		wantError bool
	}{
		{
			name:      "tab and newline characters",
			rrule:     "\t\n",
			wantError: false,
		},
		{
			name:      "mixed whitespace",
			rrule:     " \t \n ",
			wantError: false,
		},
		{
			name:      "complex valid rrule",
			rrule:     "FREQ=WEEKLY;INTERVAL=2;COUNT=10;BYDAY=MO,WE,FR",
			wantError: false,
		},
		{
			name:      "rrule with until date",
			rrule:     "FREQ=DAILY;UNTIL=20251231T235959Z",
			wantError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateRRule(tt.rrule)
			if (err != nil) != tt.wantError {
				t.Errorf("ValidateRRule(%q) error = %v, wantError %v", tt.rrule, err, tt.wantError)
			}
		})
	}
}

func TestValidateRRule_ValidationErrorFields(t *testing.T) {
	err := ValidateRRule("INVALID")
	if err == nil {
		t.Fatal("ValidateRRule(\"INVALID\") expected error but got nil")
	}

	validationErr, ok := err.(*ValidationError)
	if !ok {
		t.Fatalf("ValidateRRule error type = %T, want *ValidationError", err)
	}

	if validationErr.Field != "rrule" {
		t.Errorf("ValidationError.Field = %q, want %q", validationErr.Field, "rrule")
	}

	if !strings.Contains(validationErr.Message, "invalid RFC 5545 format") {
		t.Errorf("ValidationError.Message = %q, want to contain %q", validationErr.Message, "invalid RFC 5545 format")
	}
}
