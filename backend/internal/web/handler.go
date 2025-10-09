package web

import (
	_ "embed"
	"encoding/json"
	"net/http"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"go.uber.org/zap"
)

//go:embed dashboard.html
var dashboardHTML []byte

// Handler handles web requests for the scheduler dashboard
type Handler struct {
	db        *storage.DB
	scheduler *scheduler.Scheduler
	logger    *zap.Logger
}

// NewHandler creates a new web handler
func NewHandler(db *storage.DB, sched *scheduler.Scheduler, logger *zap.Logger) *Handler {
	return &Handler{
		db:        db,
		scheduler: sched,
		logger:    logger,
	}
}

// DashboardHandler serves the scheduler dashboard HTML
func (h *Handler) DashboardHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(dashboardHTML)
}

// StatusResponse represents the scheduler status API response
type StatusResponse struct {
	Stats     Stats              `json:"stats"`
	Schedules []ScheduleInfo     `json:"schedules"`
	UpdatedAt time.Time          `json:"updated_at"`
}

// Stats represents scheduler statistics
type Stats struct {
	Total      int       `json:"total"`
	Active     int       `json:"active"`
	Paused     int       `json:"paused"`
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
	// Get all schedules (not just active ones)
	allSchedules, err := h.getAllSchedules()
	if err != nil {
		h.logger.Error("Failed to get schedules", zap.Error(err))
		http.Error(w, "Failed to get schedules", http.StatusInternalServerError)
		return
	}

	// Build schedule info with next execution times
	scheduleInfos := make([]ScheduleInfo, 0, len(allSchedules))
	var nextUpcoming *ScheduleInfo
	var earliestNext *time.Time

	stats := Stats{
		Total: len(allSchedules),
	}

	for _, schedule := range allSchedules {
		// Get routine name and profile info
		routine, err := h.db.GetRoutine(schedule.RoutineID)
		routineName := "Unknown"
		profileID := ""
		profileName := "Unknown"

		if err == nil && routine != nil {
			routineName = routine.Name
			profileID = routine.ProfileID

			// Get profile name
			if profile, err := h.db.GetProfile(routine.ProfileID); err == nil && profile != nil {
				profileName = profile.Name
			}
		}

		// Calculate next execution
		var nextExec *time.Time
		if schedule.Enabled {
			nextExec, err = h.scheduler.GetNextExecution(schedule)
			if err != nil {
				h.logger.Warn("Failed to calculate next execution",
					zap.String("schedule_id", schedule.ScheduleID),
					zap.Error(err))
			}

			// Track earliest upcoming schedule
			if nextExec != nil && (earliestNext == nil || nextExec.Before(*earliestNext)) {
				earliestNext = nextExec
				info := ScheduleInfo{
					ID:            schedule.ScheduleID,
					Name:          schedule.Name,
					RoutineID:     schedule.RoutineID,
					RoutineName:   routineName,
					ProfileID:     profileID,
					ProfileName:   profileName,
					RRule:         schedule.RRule,
					LastExecution: schedule.LastExecution,
					NextExecution: nextExec,
					Enabled:       schedule.Enabled,
					CreatedAt:     schedule.CreatedAt,
				}
				nextUpcoming = &info
			}
		}

		// Update stats
		if schedule.Enabled {
			stats.Active++
		} else {
			stats.Paused++
		}

		scheduleInfos = append(scheduleInfos, ScheduleInfo{
			ID:            schedule.ScheduleID,
			Name:          schedule.Name,
			RoutineID:     schedule.RoutineID,
			RoutineName:   routineName,
			ProfileID:     profileID,
			ProfileName:   profileName,
			RRule:         schedule.RRule,
			LastExecution: schedule.LastExecution,
			NextExecution: nextExec,
			Enabled:       schedule.Enabled,
			CreatedAt:     schedule.CreatedAt,
		})
	}

	stats.NextUpcoming = nextUpcoming

	response := StatusResponse{
		Stats:     stats,
		Schedules: scheduleInfos,
		UpdatedAt: time.Now(),
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		h.logger.Error("Failed to encode response", zap.Error(err))
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// getAllSchedules retrieves all schedules from all routines
func (h *Handler) getAllSchedules() ([]*models.Schedule, error) {
	// Query all schedules directly from storage
	query := `
		SELECT schedule_id, routine_id, name, rrule, dtstart, exdates,
		       last_execution, notes, enabled, created_at, updated_at
		FROM schedules
		ORDER BY created_at DESC
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

// scanSchedule scans a schedule from a database row
func (h *Handler) scanSchedule(rows interface{}) (*models.Schedule, error) {
	type scanner interface {
		Scan(dest ...interface{}) error
	}

	var schedule models.Schedule
	var dtstart, lastExecution, exdatesStr, notes interface{}
	var createdAt, updatedAt string

	err := rows.(scanner).Scan(
		&schedule.ScheduleID,
		&schedule.RoutineID,
		&schedule.Name,
		&schedule.RRule,
		&dtstart,
		&exdatesStr,
		&lastExecution,
		&notes,
		&schedule.Enabled,
		&createdAt,
		&updatedAt,
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

	if notes != nil {
		if notesStr, ok := notes.(string); ok {
			schedule.Notes = notesStr
		}
	}

	schedule.CreatedAt, _ = time.Parse(time.RFC3339, createdAt)
	schedule.UpdatedAt, _ = time.Parse(time.RFC3339, updatedAt)

	return &schedule, nil
}
