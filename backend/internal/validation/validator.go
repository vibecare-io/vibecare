package validation

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
)

// Validation limits
const (
	MaxNameLength        = 100
	MaxEmailLength       = 255
	MaxDescriptionLength = 1000
	MaxNotesLength       = 5000
	MaxJSONSize          = 100000 // 100KB
	MaxArraySize         = 100
)

var (
	// Email regex pattern (RFC 5322 simplified)
	emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`)
)

// ValidationError represents a validation error
type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("validation error on field '%s': %s", e.Field, e.Message)
}

// ValidateStringLength validates that a string is within min and max length
func ValidateStringLength(field, value string, minLen, maxLen int) error {
	length := utf8.RuneCountInString(value)
	if length < minLen {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("must be at least %d characters, got %d", minLen, length),
		}
	}
	if length > maxLen {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("must not exceed %d characters, got %d", maxLen, length),
		}
	}
	return nil
}

// ValidateRequired validates that a string is not empty after trimming
func ValidateRequired(field, value string) error {
	if strings.TrimSpace(value) == "" {
		return &ValidationError{
			Field:   field,
			Message: "is required and cannot be empty",
		}
	}
	return nil
}

// ValidateEmail validates email format
func ValidateEmail(email string) error {
	if err := ValidateRequired("email", email); err != nil {
		return err
	}
	if err := ValidateStringLength("email", email, 3, MaxEmailLength); err != nil {
		return err
	}
	if !emailRegex.MatchString(email) {
		return &ValidationError{
			Field:   "email",
			Message: "invalid email format",
		}
	}
	return nil
}

// ValidateName validates a name field (profile, routine, schedule names)
func ValidateName(field, name string) error {
	if err := ValidateRequired(field, name); err != nil {
		return err
	}
	return ValidateStringLength(field, name, 1, MaxNameLength)
}

// ValidateDescription validates a description field
func ValidateDescription(description string) error {
	if description == "" {
		return nil // Description is optional
	}
	return ValidateStringLength("description", description, 0, MaxDescriptionLength)
}

// ValidateNotes validates a notes field
func ValidateNotes(notes string) error {
	if notes == "" {
		return nil // Notes are optional
	}
	return ValidateStringLength("notes", notes, 0, MaxNotesLength)
}

// ValidateJSON validates that a string is valid JSON and within size limits
func ValidateJSON(field, jsonStr string) error {
	if jsonStr == "" {
		return nil // Empty JSON is valid
	}

	// Check size
	if len(jsonStr) > MaxJSONSize {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("JSON size exceeds maximum of %d bytes", MaxJSONSize),
		}
	}

	// Validate JSON format
	var js json.RawMessage
	if err := json.Unmarshal([]byte(jsonStr), &js); err != nil {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("invalid JSON format: %v", err),
		}
	}

	return nil
}

// ValidateJSONMap validates a map can be marshaled to JSON and is within size limits
func ValidateJSONMap(field string, data map[string]string) error {
	if data == nil || len(data) == 0 {
		return nil // Empty map is valid
	}

	jsonBytes, err := json.Marshal(data)
	if err != nil {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("cannot marshal to JSON: %v", err),
		}
	}

	if len(jsonBytes) > MaxJSONSize {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("JSON size exceeds maximum of %d bytes", MaxJSONSize),
		}
	}

	return nil
}

// ValidateStringArray validates an array of strings
func ValidateStringArray(field string, arr []string, maxSize int) error {
	if len(arr) > maxSize {
		return &ValidationError{
			Field:   field,
			Message: fmt.Sprintf("array size exceeds maximum of %d items, got %d", maxSize, len(arr)),
		}
	}

	// Validate each item is not excessively long
	for i, item := range arr {
		if len(item) > MaxNameLength {
			return &ValidationError{
				Field:   field,
				Message: fmt.Sprintf("item at index %d exceeds maximum length of %d characters", i, MaxNameLength),
			}
		}
	}

	return nil
}

// ValidateUUID validates that a string is a valid UUID
func ValidateUUID(field, id string) error {
	if id == "" {
		return nil // Empty UUID is valid (will be auto-generated)
	}

	if _, err := uuid.Parse(id); err != nil {
		return &ValidationError{
			Field:   field,
			Message: "must be a valid UUID format",
		}
	}

	return nil
}

// SanitizeString removes potentially dangerous characters and trims whitespace
func SanitizeString(input string) string {
	// Trim leading/trailing whitespace
	sanitized := strings.TrimSpace(input)

	// Remove null bytes
	sanitized = strings.ReplaceAll(sanitized, "\x00", "")

	// Normalize whitespace (replace multiple spaces with single space)
	sanitized = regexp.MustCompile(`\s+`).ReplaceAllString(sanitized, " ")

	return sanitized
}

// ValidateAndSanitizeName validates and sanitizes a name field
func ValidateAndSanitizeName(field, name string) (string, error) {
	sanitized := SanitizeString(name)
	if err := ValidateName(field, sanitized); err != nil {
		return "", err
	}
	return sanitized, nil
}

// ValidateAndSanitizeDescription validates and sanitizes a description
func ValidateAndSanitizeDescription(description string) (string, error) {
	sanitized := SanitizeString(description)
	if err := ValidateDescription(sanitized); err != nil {
		return "", err
	}
	return sanitized, nil
}

// ValidateAndSanitizeNotes validates and sanitizes notes
func ValidateAndSanitizeNotes(notes string) (string, error) {
	sanitized := SanitizeString(notes)
	if err := ValidateNotes(sanitized); err != nil {
		return "", err
	}
	return sanitized, nil
}