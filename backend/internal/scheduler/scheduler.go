package scheduler

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/teambition/rrule-go"
	"github.com/vibecare-io/vibecare/backend/internal/models"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Scheduler manages schedule execution and event dispatching
type Scheduler struct {
	db            *storage.DB
	eventHub      *EventHub
	logger        *zap.Logger
	checkInterval time.Duration
	ctx           context.Context
	cancel        context.CancelFunc
}

// NewScheduler creates a new Scheduler
func NewScheduler(db *storage.DB, eventHub *EventHub, logger *zap.Logger) *Scheduler {
	ctx, cancel := context.WithCancel(context.Background())
	return &Scheduler{
		db:            db,
		eventHub:      eventHub,
		logger:        logger,
		checkInterval: 10 * time.Second, // Check every 10 seconds for better precision
		ctx:           ctx,
		cancel:        cancel,
	}
}

// Start begins the scheduler loop
func (s *Scheduler) Start() {
	s.logger.Info("Starting scheduler",
		zap.Duration("check_interval", s.checkInterval))

	ticker := time.NewTicker(s.checkInterval)
	defer ticker.Stop()

	// Run once immediately on startup
	s.checkAndDispatch()

	for {
		select {
		case <-ticker.C:
			s.checkAndDispatch()
		case <-s.ctx.Done():
			s.logger.Info("Scheduler stopped")
			return
		}
	}
}

// Stop stops the scheduler
func (s *Scheduler) Stop() {
	s.logger.Info("Stopping scheduler")
	s.cancel()
}

// checkAndDispatch checks for schedules that need to be triggered and dispatches events
func (s *Scheduler) checkAndDispatch() {
	schedules, err := s.db.GetActiveSchedules()
	if err != nil {
		s.logger.Error("Failed to get active schedules", zap.Error(err))
		return
	}

	s.logger.Debug("Checking schedules",
		zap.Int("schedule_count", len(schedules)))

	now := time.Now()
	for _, schedule := range schedules {
		if s.shouldTrigger(schedule, now) {
			s.dispatchScheduleEvent(schedule)
		}
	}
}

// shouldTrigger determines if a schedule should be triggered at the given time
// Now simplified to just check the pre-calculated next_execution field
func (s *Scheduler) shouldTrigger(schedule *models.Schedule, now time.Time) bool {
	// Check if schedule has a next_execution time set
	if schedule.NextExecution == nil {
		// No next execution scheduled (either completed one-time or no valid next occurrence)
		return false
	}

	// Trigger if next_execution is now or in the past
	if now.After(*schedule.NextExecution) || now.Equal(*schedule.NextExecution) {
		s.logger.Info("Schedule should be triggered",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.String("schedule_type", string(schedule.ScheduleType)),
			zap.Time("next_execution", *schedule.NextExecution))
		return true
	}

	return false
}

// parseRRule parses the RRule RFC 5545 string from a schedule
func (s *Scheduler) parseRRule(schedule *models.Schedule) (*rrule.Set, error) {
	// Determine dtstart
	dtstart := time.Now()
	if schedule.DTStart != nil {
		dtstart = *schedule.DTStart
	}

	// Build the complete RRule string with DTSTART
	rruleStr := "DTSTART:" + dtstart.Format("20060102T150405Z") + "\nRRULE:" + schedule.RRule

	// Parse the RRule using rrule-go
	rule, err := rrule.StrToRRule(rruleStr)
	if err != nil {
		return nil, err
	}

	// Create an RSet and add the rule
	rset := &rrule.Set{}
	rset.RRule(rule)

	// Add exclusion dates if present
	for _, exdateStr := range schedule.ExDates {
		exdate, err := time.Parse(time.RFC3339, exdateStr)
		if err != nil {
			s.logger.Warn("Failed to parse exclusion date",
				zap.String("exdate", exdateStr),
				zap.Error(err))
			continue
		}
		rset.ExDate(exdate)
	}

	return rset, nil
}

// dispatchScheduleEvent creates and dispatches a schedule triggered event
func (s *Scheduler) dispatchScheduleEvent(schedule *models.Schedule) {
	// IMPORTANT: Update execution BEFORE dispatch (optimistic locking)
	// This prevents race conditions where the same schedule triggers multiple times
	dtstart := time.Now()
	if schedule.DTStart != nil {
		dtstart = *schedule.DTStart
	}

	if err := s.db.UpdateScheduleExecution(schedule.ScheduleID, schedule.ScheduleType, schedule.RRule, dtstart); err != nil {
		s.logger.Error("Failed to update schedule execution atomically",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Error(err))
		return // Don't dispatch if we can't update - prevents duplicate triggers
	}

	// Get the routine details
	routine, err := s.db.GetRoutine(schedule.RoutineID)
	if err != nil {
		s.logger.Error("Failed to get routine for schedule",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.String("routine_id", schedule.RoutineID),
			zap.Error(err))
		return
	}

	if routine == nil {
		s.logger.Warn("Routine not found for schedule",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.String("routine_id", schedule.RoutineID))
		return
	}

	// Get profile ID from routine
	profileID := routine.ProfileID

	// Fetch action IDs from schedule_actions join table
	actions, err := s.db.GetScheduleActions(schedule.ScheduleID)
	if err != nil {
		s.logger.Error("Failed to fetch schedule actions",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Error(err))
		// Continue with empty action list rather than failing the entire dispatch
		actions = []*models.Action{}
	}

	actionIDs := make([]string, len(actions))
	for i, action := range actions {
		actionIDs[i] = action.ID
	}

	// Create the dispatch event
	event := &pb.DispatchEvent{
		EventId:   uuid.New().String(),
		EventType: pb.EventType_EVENT_TYPE_SCHEDULE_TRIGGERED,
		Timestamp: timestamppb.Now(),
		Payload: &pb.DispatchEvent_ScheduleTriggered{
			ScheduleTriggered: &pb.ScheduleTriggeredEvent{
				ScheduleId:    schedule.ScheduleID,
				ScheduleName:  &schedule.Name,
				RoutineId:     routine.ID,
				RoutineName:   routine.Name,
				ScheduledTime: timestamppb.Now(),
				ActionIds:     actionIDs,
			},
		},
	}

	// Broadcast the event to subscribed clients
	s.eventHub.Broadcast(profileID, event)

	s.logger.Info("Dispatched schedule event",
		zap.String("schedule_id", schedule.ScheduleID),
		zap.String("routine_id", routine.ID),
		zap.String("routine_name", routine.Name),
		zap.String("profile_id", profileID))
}

// GetNextExecution returns the pre-calculated next execution time for a schedule
// Returns nil if schedule is disabled or has no future occurrences
func (s *Scheduler) GetNextExecution(schedule *models.Schedule) (*time.Time, error) {
	if !schedule.Enabled {
		return nil, nil
	}

	// Simply return the pre-calculated next_execution field
	// No need to parse RRule - it's already calculated in the database
	return schedule.NextExecution, nil
}
