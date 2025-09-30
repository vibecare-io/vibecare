package telemetry

import (
	"context"

	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

// LoggerWithTrace wraps a Zap logger and automatically adds trace context
type LoggerWithTrace struct {
	logger *zap.Logger
}

// NewLoggerWithTrace creates a logger that automatically includes trace context
func NewLoggerWithTrace(logger *zap.Logger) *LoggerWithTrace {
	return &LoggerWithTrace{logger: logger}
}

// WithContext returns a logger with trace context fields added
func (l *LoggerWithTrace) WithContext(ctx context.Context) *zap.Logger {
	span := trace.SpanFromContext(ctx)
	if !span.SpanContext().IsValid() {
		return l.logger
	}

	return l.logger.With(
		zap.String("trace_id", span.SpanContext().TraceID().String()),
		zap.String("span_id", span.SpanContext().SpanID().String()),
	)
}

// Debug logs at debug level with trace context
func (l *LoggerWithTrace) Debug(ctx context.Context, msg string, fields ...zap.Field) {
	l.WithContext(ctx).Debug(msg, fields...)
}

// Info logs at info level with trace context
func (l *LoggerWithTrace) Info(ctx context.Context, msg string, fields ...zap.Field) {
	l.WithContext(ctx).Info(msg, fields...)
}

// Warn logs at warn level with trace context
func (l *LoggerWithTrace) Warn(ctx context.Context, msg string, fields ...zap.Field) {
	l.WithContext(ctx).Warn(msg, fields...)
}

// Error logs at error level with trace context
func (l *LoggerWithTrace) Error(ctx context.Context, msg string, fields ...zap.Field) {
	l.WithContext(ctx).Error(msg, fields...)
}

// Fatal logs at fatal level with trace context
func (l *LoggerWithTrace) Fatal(ctx context.Context, msg string, fields ...zap.Field) {
	l.WithContext(ctx).Fatal(msg, fields...)
}

// Base returns the underlying Zap logger
func (l *LoggerWithTrace) Base() *zap.Logger {
	return l.logger
}

// LogErrorWithContext logs an error with full context including error details
func LogErrorWithContext(ctx context.Context, logger *zap.Logger, err error, msg string, additionalFields ...zap.Field) {
	if err == nil {
		return
	}

	// Get trace context
	span := trace.SpanFromContext(ctx)
	fields := []zap.Field{zap.Error(err)}

	if span.SpanContext().IsValid() {
		fields = append(fields,
			zap.String("trace_id", span.SpanContext().TraceID().String()),
			zap.String("span_id", span.SpanContext().SpanID().String()),
		)
	}

	// Analyze error for additional context
	info := AnalyzeError(err)
	fields = append(fields,
		zap.String("error.type", string(info.Type)),
		zap.String("error.fingerprint", info.Fingerprint),
		zap.String("error.source", info.SourceFile),
		zap.Int("error.line", info.SourceLine),
	)

	if info.Field != "" {
		fields = append(fields, zap.String("error.field", info.Field))
	}

	// Add any additional fields
	fields = append(fields, additionalFields...)

	logger.Error(msg, fields...)
}
