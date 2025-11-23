package web

import (
	"net/http"
	"strings"

	"github.com/vibecare-io/vibecare/backend/internal/telemetry"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

// ServeSVGIcon serves SVG icon files from embedded data
func ServeSVGIcon(w http.ResponseWriter, r *http.Request, iconLoader IconDataGetter, logger *zap.Logger) {
	// Create trace-aware logger
	traceLogger := telemetry.NewLoggerWithTrace(logger)
	span := trace.SpanFromContext(r.Context())

	// Only allow GET requests
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract icon ID from URL path
	// URL format: /api/icons/{icon-id}.svg
	path := strings.TrimPrefix(r.URL.Path, "/api/icons/")
	iconID := strings.TrimSuffix(path, ".svg")

	if iconID == "" {
		http.Error(w, "Icon ID required", http.StatusBadRequest)
		return
	}

	// Add icon ID to span for tracing
	if span.IsRecording() {
		span.SetAttributes(attribute.String("icon.id", iconID))
	}

	traceLogger.Debug(r.Context(), "Serving SVG icon", zap.String("icon_id", iconID))

	// Get icon data from embedded files
	svgData, err := iconLoader.GetIconData(iconID)
	if err != nil {
		traceLogger.Warn(r.Context(), "Icon not found", zap.String("icon_id", iconID), zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		http.Error(w, "Icon not found", http.StatusNotFound)
		return
	}

	// Set content type and caching headers
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("Cache-Control", "public, max-age=86400") // Cache for 24 hours
	w.Header().Set("Access-Control-Allow-Origin", "*")        // Allow CORS for local dev

	// Write SVG content
	if _, err := w.Write(svgData); err != nil {
		traceLogger.Error(r.Context(), "Failed to write response", zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		return
	}

	// Add size to span attributes
	if span.IsRecording() {
		span.SetAttributes(attribute.Int("icon.size_bytes", len(svgData)))
	}

	traceLogger.Debug(r.Context(), "Successfully served SVG icon", zap.String("icon_id", iconID), zap.Int("size_bytes", len(svgData)))
}

// IconDataGetter defines interface for getting icon data
type IconDataGetter interface {
	GetIconData(iconID string) ([]byte, error)
}
