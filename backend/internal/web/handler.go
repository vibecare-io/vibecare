package web

import (
	"context"
	_ "embed"
	"encoding/json"
	"net/http"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/mcp"
	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"github.com/vibecare-io/vibecare/backend/internal/telemetry"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

//go:embed dashboard.html
var dashboardHTML []byte

// Handler handles web requests for the scheduler dashboard
type Handler struct {
	db        *storage.DB
	scheduler *scheduler.Scheduler
	mcpServer *mcp.Server
	logger    *zap.Logger
}

// NewHandler creates a new web handler
func NewHandler(db *storage.DB, sched *scheduler.Scheduler, mcpServer *mcp.Server, logger *zap.Logger) *Handler {
	return &Handler{
		db:        db,
		scheduler: sched,
		mcpServer: mcpServer,
		logger:    logger,
	}
}

// DashboardHandler serves the scheduler dashboard HTML
func (h *Handler) DashboardHandler(w http.ResponseWriter, r *http.Request) {
	// Create trace-aware logger
	logger := telemetry.NewLoggerWithTrace(h.logger)

	logger.Debug(r.Context(), "Serving dashboard page")

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(dashboardHTML)
}

// StatusResponse represents the scheduler status API response
type StatusResponse struct {
	Stats     Stats          `json:"stats"`
	Schedules []ScheduleInfo `json:"schedules"`
	UpdatedAt time.Time      `json:"updated_at"`
}

// Stats represents scheduler statistics
type Stats struct {
	Total        int           `json:"total"`
	Active       int           `json:"active"`
	Paused       int           `json:"paused"`
	NextUpcoming *ScheduleInfo `json:"next_upcoming"`
}

// ScheduleInfo represents schedule information for the dashboard
type ScheduleInfo struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	RoutineID     string     `json:"routine_id"`
	RoutineName   string     `json:"routine_name"`
	ProfileID     string     `json:"profile_id"`
	ProfileName   string     `json:"profile_name"`
	RRule         string     `json:"rrule"`
	LastExecution *time.Time `json:"last_execution"`
	NextExecution *time.Time `json:"next_execution"`
	Enabled       bool       `json:"enabled"`
	CreatedAt     time.Time  `json:"created_at"`
}

// StatusHandler serves the scheduler status as JSON
func (h *Handler) StatusHandler(w http.ResponseWriter, r *http.Request) {
	// Create trace-aware logger
	logger := telemetry.NewLoggerWithTrace(h.logger)
	span := trace.SpanFromContext(r.Context())

	logger.Debug(r.Context(), "StatusHandler started")

	// Add timeout to prevent indefinite hangs
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// Check if context already cancelled
	select {
	case <-ctx.Done():
		err := ctx.Err()
		logger.Error(r.Context(), "Request timeout before execution", zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		http.Error(w, "Request timeout", http.StatusGatewayTimeout)
		return
	default:
	}

	// Get all schedules (not just active ones)
	allSchedules, err := h.getAllSchedules()
	if err != nil {
		logger.Error(r.Context(), "Failed to get schedules", zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		http.Error(w, "Failed to get schedules", http.StatusInternalServerError)
		return
	}
	logger.Debug(r.Context(), "Fetched schedules", zap.Int("count", len(allSchedules)))

	// Build schedule info and calculate stats
	logger.Debug(r.Context(), "Building schedule info", zap.Int("total_schedules", len(allSchedules)))
	scheduleInfos := make([]ScheduleInfo, 0, len(allSchedules))
	stats := Stats{
		Total: len(allSchedules),
	}

	for i, schedule := range allSchedules {
		// Create span for each schedule processing
		ctx, scheduleSpan := trace.SpanFromContext(r.Context()).TracerProvider().Tracer("vibecare.http.server").Start(r.Context(), "process_schedule",
			trace.WithAttributes(
				attribute.Int("schedule.index", i),
				attribute.String("schedule.id", schedule.ScheduleID),
				attribute.String("schedule.name", schedule.Name),
				attribute.Bool("schedule.enabled", schedule.Enabled),
			))

		logger.Debug(ctx, ">>> Processing schedule",
			zap.Int("index", i),
			zap.Int("total", len(allSchedules)),
			zap.String("schedule_id", schedule.ScheduleID),
			zap.String("name", schedule.Name),
			zap.String("rrule", schedule.RRule),
			zap.Bool("enabled", schedule.Enabled))

		// Update stats
		if schedule.Enabled {
			stats.Active++
		} else {
			stats.Paused++
		}

		// Calculate next execution for enabled schedules
		var nextExec *time.Time
		if schedule.Enabled {
			logger.Debug(ctx, "    Calculating next execution for schedule",
				zap.String("schedule_id", schedule.ScheduleID),
				zap.String("rrule", schedule.RRule))

			// Create sub-span for the expensive calculation
			_, execSpan := trace.SpanFromContext(ctx).TracerProvider().Tracer("vibecare.http.server").Start(ctx, "calculate_next_execution",
				trace.WithAttributes(
					attribute.String("schedule.id", schedule.ScheduleID),
					attribute.String("schedule.rrule", schedule.RRule),
				))

			// Use a channel with timeout to prevent infinite hangs from malformed RRules
			type result struct {
				nextExec *time.Time
				err      error
			}
			resultCh := make(chan result, 1)

			go func() {
				next, err := h.scheduler.GetNextExecution(schedule)
				resultCh <- result{nextExec: next, err: err}
			}()

			select {
			case res := <-resultCh:
				nextExec = res.nextExec
				err = res.err
				if err != nil {
					logger.Error(ctx, "    FAILED to calculate next execution",
						zap.Int("index", i),
						zap.String("schedule_id", schedule.ScheduleID),
						zap.String("rrule", schedule.RRule),
						zap.Error(err))
					telemetry.RecordErrorWithDetails(execSpan, err, "")
				} else {
					logger.Debug(ctx, "    Calculated next execution successfully",
						zap.String("schedule_id", schedule.ScheduleID),
						zap.Any("next_execution", nextExec))
				}
			case <-time.After(2 * time.Second):
				// Timeout - probably a malformed RRule causing infinite loop
				logger.Error(ctx, "    TIMEOUT calculating next execution - malformed RRule?",
					zap.String("schedule_id", schedule.ScheduleID),
					zap.String("rrule", schedule.RRule),
					zap.String("error", "timeout after 2 seconds"))
				execSpan.SetAttributes(attribute.String("error.type", "timeout"))
				nextExec = nil
			}

			execSpan.End()
		}

		// Build schedule info
		info := ScheduleInfo{
			ID:            schedule.ScheduleID,
			Name:          schedule.Name,
			RoutineID:     schedule.RoutineID,
			RoutineName:   schedule.RoutineName,
			ProfileID:     schedule.ProfileID,
			ProfileName:   schedule.ProfileName,
			RRule:         schedule.RRule,
			LastExecution: schedule.LastExecution,
			NextExecution: nextExec,
			Enabled:       schedule.Enabled,
			CreatedAt:     schedule.CreatedAt,
		}
		scheduleInfos = append(scheduleInfos, info)

		logger.Debug(ctx, "<<< Finished processing schedule",
			zap.Int("index", i),
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Bool("has_next_execution", nextExec != nil))

		scheduleSpan.End()
	}

	logger.Debug(r.Context(), "Finished processing schedules",
		zap.Int("active", stats.Active),
		zap.Int("paused", stats.Paused))

	// NextUpcoming not calculated since we skip next execution times
	stats.NextUpcoming = nil

	// Add span attributes for observability
	if span.IsRecording() {
		span.SetAttributes(
			attribute.Int("scheduler.schedule_count", stats.Total),
			attribute.Int("scheduler.active_count", stats.Active),
			attribute.Int("scheduler.paused_count", stats.Paused),
		)
	}

	response := StatusResponse{
		Stats:     stats,
		Schedules: scheduleInfos,
		UpdatedAt: time.Now(),
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		logger.Error(r.Context(), "Failed to encode response", zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}

	logger.Debug(r.Context(), "StatusHandler completed successfully",
		zap.Int("schedule_count", len(scheduleInfos)))
}

// getAllSchedules retrieves all schedules with joined routine and profile data
func (h *Handler) getAllSchedules() ([]*models.Schedule, error) {
	// Single JOIN query to get schedules with routine and profile names
	query := `
		SELECT
			s.schedule_id, s.profile_id, s.routine_id, s.name, s.rrule,
			s.dtstart, s.exdates, s.last_execution, s.next_execution, s.notes, s.enabled,
			s.created_at, s.updated_at,
			COALESCE(r.name, 'Unknown') as routine_name,
			COALESCE(p.name, 'Unknown') as profile_name
		FROM schedules s
		LEFT JOIN routines r ON s.routine_id = r.id
		LEFT JOIN profiles p ON s.profile_id = p.id
		ORDER BY s.created_at DESC
	`

	rows, err := h.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var schedules []*models.Schedule
	for rows.Next() {
		schedule, err := h.scanSchedule(rows)
		if err != nil {
			return nil, err
		}
		schedules = append(schedules, schedule)
	}

	return schedules, nil
}

// scanSchedule scans a schedule from a database row with joined data
func (h *Handler) scanSchedule(rows interface{}) (*models.Schedule, error) {
	type scanner interface {
		Scan(dest ...interface{}) error
	}

	var schedule models.Schedule
	var dtstart, lastExecution, nextExecution, exdatesStr, notes interface{}
	var createdAt, updatedAt string

	err := rows.(scanner).Scan(
		&schedule.ScheduleID,
		&schedule.ProfileID,
		&schedule.RoutineID,
		&schedule.Name,
		&schedule.RRule,
		&dtstart,
		&exdatesStr,
		&lastExecution,
		&nextExecution,
		&notes,
		&schedule.Enabled,
		&createdAt,
		&updatedAt,
		&schedule.RoutineName,
		&schedule.ProfileName,
	)
	if err != nil {
		return nil, err
	}

	// Parse optional fields
	if dtstart != nil {
		if dtStr, ok := dtstart.(string); ok && dtStr != "" {
			t, _ := time.Parse(time.RFC3339, dtStr)
			schedule.DTStart = &t
		}
	}

	if lastExecution != nil {
		if leStr, ok := lastExecution.(string); ok && leStr != "" {
			t, _ := time.Parse(time.RFC3339, leStr)
			schedule.LastExecution = &t
		}
	}

	if nextExecution != nil {
		if neStr, ok := nextExecution.(string); ok && neStr != "" {
			t, _ := time.Parse(time.RFC3339, neStr)
			schedule.NextExecution = &t
		}
	}

	if notes != nil {
		if notesStr, ok := notes.(string); ok {
			schedule.Notes = notesStr
		}
	}

	schedule.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	schedule.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &schedule, nil
}

// MCPToolsResponse represents the MCP tools API response
type MCPToolsResponse struct {
	Enabled   bool           `json:"enabled"`
	Tools     []mcp.Tool     `json:"tools,omitempty"`
	Resources []mcp.Resource `json:"resources,omitempty"`
}

// MCPToolsHandler returns the list of available MCP tools and resources
func (h *Handler) MCPToolsHandler(w http.ResponseWriter, r *http.Request) {
	// Create trace-aware logger
	logger := telemetry.NewLoggerWithTrace(h.logger)
	span := trace.SpanFromContext(r.Context())

	w.Header().Set("Content-Type", "application/json")

	// Check if MCP server is enabled
	if h.mcpServer == nil {
		if span.IsRecording() {
			span.SetAttributes(attribute.Bool("mcp.enabled", false))
		}

		response := MCPToolsResponse{
			Enabled: false,
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			logger.Error(r.Context(), "Failed to encode MCP response", zap.Error(err))
			if span.IsRecording() {
				telemetry.RecordErrorWithDetails(span, err, "")
			}
			http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		}
		return
	}

	// Get tools and resources from MCP server
	tools := h.mcpServer.GetTools()
	resources := h.mcpServer.GetResources()

	// Add span attributes for observability
	if span.IsRecording() {
		span.SetAttributes(
			attribute.Bool("mcp.enabled", true),
			attribute.Int("mcp.tool_count", len(tools)),
			attribute.Int("mcp.resource_count", len(resources)),
		)
	}

	response := MCPToolsResponse{
		Enabled:   true,
		Tools:     tools,
		Resources: resources,
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		logger.Error(r.Context(), "Failed to encode MCP response", zap.Error(err))
		if span.IsRecording() {
			telemetry.RecordErrorWithDetails(span, err, "")
		}
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}
