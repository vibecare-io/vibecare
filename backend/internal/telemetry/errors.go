package telemetry

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"runtime"
	"strings"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc/status"
)

// ErrorType classifies different types of errors
type ErrorType string

const (
	ErrorTypeValidation ErrorType = "validation"
	ErrorTypeDatabase   ErrorType = "database"
	ErrorTypeNetwork    ErrorType = "network"
	ErrorTypeInternal   ErrorType = "internal"
	ErrorTypeNotFound   ErrorType = "not_found"
	ErrorTypeConflict   ErrorType = "conflict"
	ErrorTypeUnknown    ErrorType = "unknown"
)

// ErrorInfo contains structured error information
type ErrorInfo struct {
	Type        ErrorType
	Message     string
	Field       string // For validation errors
	StackTrace  string
	SourceFile  string
	SourceLine  int
	Fingerprint string
	GRPCCode    string
}

// ClassifyError determines the error type based on error message and gRPC status
func ClassifyError(err error, st *status.Status) ErrorType {
	if err == nil {
		return ErrorTypeUnknown
	}

	msg := strings.ToLower(err.Error())

	// Check gRPC status code first
	if st != nil {
		switch st.Code() {
		case 3: // INVALID_ARGUMENT
			return ErrorTypeValidation
		case 5: // NOT_FOUND
			return ErrorTypeNotFound
		case 6: // ALREADY_EXISTS
			return ErrorTypeConflict
		case 14: // UNAVAILABLE
			return ErrorTypeNetwork
		}
	}

	// Check error message for common patterns
	switch {
	case strings.Contains(msg, "validation"):
		return ErrorTypeValidation
	case strings.Contains(msg, "invalid"):
		return ErrorTypeValidation
	case strings.Contains(msg, "required"):
		return ErrorTypeValidation
	case strings.Contains(msg, "database"):
		return ErrorTypeDatabase
	case strings.Contains(msg, "sql"):
		return ErrorTypeDatabase
	case strings.Contains(msg, "not found"):
		return ErrorTypeNotFound
	case strings.Contains(msg, "already exists"):
		return ErrorTypeConflict
	case strings.Contains(msg, "network"):
		return ErrorTypeNetwork
	case strings.Contains(msg, "connection"):
		return ErrorTypeNetwork
	default:
		return ErrorTypeInternal
	}
}

// ExtractFieldName attempts to extract field name from validation errors
func ExtractFieldName(err error) string {
	if err == nil {
		return ""
	}

	msg := err.Error()

	// Try common patterns: "field 'name':", "on field 'name'", "invalid name"
	patterns := []string{
		"field '",
		"field \"",
		"on field '",
		"on field \"",
	}

	for _, pattern := range patterns {
		if idx := strings.Index(msg, pattern); idx >= 0 {
			start := idx + len(pattern)
			if end := strings.IndexAny(msg[start:], "'\""); end >= 0 {
				return msg[start : start+end]
			}
		}
	}

	// Try pattern: "invalid <field>"
	if strings.HasPrefix(msg, "invalid ") {
		parts := strings.Split(msg, " ")
		if len(parts) >= 2 {
			field := strings.TrimSuffix(parts[1], ":")
			return field
		}
	}

	return ""
}

// CaptureStackTrace captures the current stack trace
func CaptureStackTrace(skip int) string {
	var buf strings.Builder
	pc := make([]uintptr, 32)
	n := runtime.Callers(skip+2, pc)
	frames := runtime.CallersFrames(pc[:n])

	for {
		frame, more := frames.Next()
		// Skip runtime and internal packages
		if !strings.Contains(frame.File, "runtime/") &&
			!strings.Contains(frame.File, "testing/") {
			fmt.Fprintf(&buf, "%s:%d %s\n", frame.File, frame.Line, frame.Function)
		}
		if !more {
			break
		}
	}

	return buf.String()
}

// GetSourceLocation returns the file and line where the error occurred
func GetSourceLocation(skip int) (string, int) {
	_, file, line, ok := runtime.Caller(skip + 1)
	if !ok {
		return "", 0
	}

	// Shorten the file path to be relative to the project root
	if idx := strings.Index(file, "/backend/"); idx >= 0 {
		file = file[idx+1:]
	}

	return file, line
}

// GenerateErrorFingerprint creates a hash for grouping similar errors
func GenerateErrorFingerprint(errType ErrorType, message string, file string, line int) string {
	// Normalize message by removing dynamic content
	normalized := message

	// Remove UUIDs
	normalized = strings.ReplaceAll(normalized, "-", "")

	// Remove numbers (IDs, counts, etc.)
	for _, r := range "0123456789" {
		normalized = strings.ReplaceAll(normalized, string(r), "X")
	}

	// Create fingerprint from: error type + normalized message + source location
	fingerprint := fmt.Sprintf("%s:%s:%s:%d", errType, normalized, file, line)

	// Hash to create shorter, consistent ID
	hash := sha256.Sum256([]byte(fingerprint))
	return hex.EncodeToString(hash[:8]) // Use first 8 bytes (16 hex chars)
}

// AnalyzeError extracts comprehensive error information
func AnalyzeError(err error) ErrorInfo {
	if err == nil {
		return ErrorInfo{Type: ErrorTypeUnknown}
	}

	st, _ := status.FromError(err)
	errType := ClassifyError(err, st)
	file, line := GetSourceLocation(2)
	stackTrace := CaptureStackTrace(2)

	info := ErrorInfo{
		Type:        errType,
		Message:     err.Error(),
		Field:       ExtractFieldName(err),
		StackTrace:  stackTrace,
		SourceFile:  file,
		SourceLine:  line,
		Fingerprint: GenerateErrorFingerprint(errType, err.Error(), file, line),
	}

	if st != nil {
		info.GRPCCode = st.Code().String()
	}

	return info
}

// RecordErrorWithDetails records an error with comprehensive details in the span
func RecordErrorWithDetails(span trace.Span, err error, requestPayload string) {
	if err == nil || span == nil {
		return
	}

	// Analyze the error
	info := AnalyzeError(err)

	// Set span status to Error
	span.SetStatus(codes.Error, info.Message)

	// Record the error
	span.RecordError(err)

	// Add detailed error attributes
	attrs := []attribute.KeyValue{
		attribute.String("error.type", string(info.Type)),
		attribute.String("error.message", info.Message),
		attribute.String("error.fingerprint", info.Fingerprint),
		attribute.String("error.source_file", info.SourceFile),
		attribute.Int("error.source_line", info.SourceLine),
	}

	if info.Field != "" {
		attrs = append(attrs, attribute.String("error.field", info.Field))
	}

	if info.GRPCCode != "" {
		attrs = append(attrs, attribute.String("error.grpc_code", info.GRPCCode))
	}

	span.SetAttributes(attrs...)

	// Add error event with stack trace
	span.AddEvent("error.occurred", trace.WithAttributes(
		attribute.String("error.type", string(info.Type)),
		attribute.String("error.message", info.Message),
		attribute.String("error.stack_trace", info.StackTrace),
		attribute.String("error.request_payload", requestPayload),
	))
}

// RecoverPanic recovers from a panic and records it as an error
func RecoverPanic(span trace.Span, requestPayload string) {
	if r := recover(); r != nil {
		var err error
		switch x := r.(type) {
		case string:
			err = errors.New(x)
		case error:
			err = x
		default:
			err = fmt.Errorf("panic: %v", r)
		}

		// Capture panic stack trace
		stackTrace := CaptureStackTrace(0)

		// Record panic as error
		span.SetStatus(codes.Error, fmt.Sprintf("panic: %v", r))
		span.RecordError(err)

		span.SetAttributes(
			attribute.String("error.type", "panic"),
			attribute.String("error.message", err.Error()),
		)

		span.AddEvent("panic.occurred", trace.WithAttributes(
			attribute.String("panic.value", fmt.Sprintf("%v", r)),
			attribute.String("panic.stack_trace", stackTrace),
			attribute.String("error.request_payload", requestPayload),
		))
	}
}
