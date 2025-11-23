package web

import (
	"context"
	"fmt"
	"net/http"
	"runtime/debug"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/internal/telemetry"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

// contextKey is a custom type for context keys to avoid collisions
type contextKey string

const (
	requestIDKey contextKey = "request_id"
)

// RequestIDMiddleware generates or accepts a request ID for each request
func RequestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check if request already has an ID from client
		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			// Generate new UUID if not provided
			requestID = uuid.New().String()
		}

		// Add to request context
		ctx := context.WithValue(r.Context(), requestIDKey, requestID)
		r = r.WithContext(ctx)

		// Set response header
		w.Header().Set("X-Request-ID", requestID)

		next.ServeHTTP(w, r)
	})
}

// GetRequestID extracts the request ID from context
func GetRequestID(ctx context.Context) string {
	if requestID, ok := ctx.Value(requestIDKey).(string); ok {
		return requestID
	}
	return ""
}

// responseWriter wraps http.ResponseWriter to capture status code and bytes written
type responseWriter struct {
	http.ResponseWriter
	statusCode   int
	bytesWritten int
}

func newResponseWriter(w http.ResponseWriter) *responseWriter {
	// Default status code is 200 if WriteHeader is never called
	return &responseWriter{
		ResponseWriter: w,
		statusCode:     http.StatusOK,
	}
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	n, err := rw.ResponseWriter.Write(b)
	rw.bytesWritten += n
	return n, err
}

// LoggingMiddleware logs HTTP requests with structured fields including trace context
func LoggingMiddleware(logger *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			startTime := time.Now()

			// Get request ID from context
			requestID := GetRequestID(r.Context())

			// Create trace-aware logger
			traceLogger := telemetry.NewLoggerWithTrace(logger)

			// Log request start
			traceLogger.Info(r.Context(), "http.request.start",
				zap.String("request_id", requestID),
				zap.String("http.method", r.Method),
				zap.String("http.path", r.URL.Path),
				zap.String("http.query", r.URL.RawQuery),
				zap.String("http.user_agent", r.UserAgent()),
				zap.String("http.remote_addr", r.RemoteAddr),
			)

			// Wrap response writer to capture status code
			rw := newResponseWriter(w)

			// Process request
			next.ServeHTTP(rw, r)

			// Calculate duration
			duration := time.Since(startTime)

			// Log request completion with trace context
			fields := []zap.Field{
				zap.String("request_id", requestID),
				zap.String("http.method", r.Method),
				zap.String("http.path", r.URL.Path),
				zap.Int("http.status", rw.statusCode),
				zap.Int("http.bytes_written", rw.bytesWritten),
				zap.Duration("http.duration", duration),
				zap.Float64("http.duration_ms", float64(duration.Milliseconds())),
			}

			// Determine log level based on status code
			if rw.statusCode >= 500 {
				traceLogger.Error(r.Context(), "http.request.complete", fields...)
			} else if rw.statusCode >= 400 {
				traceLogger.Warn(r.Context(), "http.request.complete", fields...)
			} else {
				traceLogger.Info(r.Context(), "http.request.complete", fields...)
			}
		})
	}
}

// PanicRecoveryMiddleware catches panics and returns 500 response
func PanicRecoveryMiddleware(logger *zap.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if recovered := recover(); recovered != nil {
					// Capture stack trace
					stackTrace := string(debug.Stack())

					// Get request ID for correlation
					requestID := GetRequestID(r.Context())

					// Create trace-aware logger
					traceLogger := telemetry.NewLoggerWithTrace(logger)

					// Log panic with full details
					traceLogger.Error(r.Context(), "http.panic.recovered",
						zap.String("request_id", requestID),
						zap.String("http.method", r.Method),
						zap.String("http.path", r.URL.Path),
						zap.Any("panic", recovered),
						zap.String("stack_trace", stackTrace),
					)

					// Record error in span if trace context exists
					span := trace.SpanFromContext(r.Context())
					if span.IsRecording() {
						span.SetStatus(codes.Error, fmt.Sprintf("panic: %v", recovered))
						span.RecordError(fmt.Errorf("panic: %v", recovered))
						span.SetAttributes(
							attribute.String("panic.value", fmt.Sprintf("%v", recovered)),
							attribute.String("panic.stack_trace", stackTrace),
						)
					}

					// Return 500 response
					w.WriteHeader(http.StatusInternalServerError)
					w.Write([]byte("Internal Server Error"))
				}
			}()

			next.ServeHTTP(w, r)
		})
	}
}
