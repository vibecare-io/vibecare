package scheduler

import (
	"context"
	"encoding/json"
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
		checkInterval: 1 * time.Minute, // Check every minute
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
func (s *Scheduler) shouldTrigger(schedule *models.Schedule, now time.Time) bool {
	// Parse RRule
	rruleSet, err := s.parseRRule(schedule)
	if err != nil {
		s.logger.Error("Failed to parse RRule",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Error(err))
		return false
	}

	// Determine the time window to check
	// We check from last_execution (or dtstart) to now
	var startTime time.Time
	if schedule.LastExecution != nil {
		startTime = *schedule.LastExecution
	} else if schedule.DTStart != nil {
		startTime = *schedule.DTStart
	} else {
		// No start time, use a reasonable default
		startTime = now.Add(-24 * time.Hour)
	}

	// Get all occurrences between last execution and now
	occurrences := rruleSet.Between(startTime, now, true)

	// Check if there are any occurrences in this window
	if len(occurrences) > 0 {
		s.logger.Info("Schedule should be triggered",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Time("last_occurrence", occurrences[len(occurrences)-1]))
		return true
	}

	return false
}

// parseRRule parses the RRule JSON from a schedule
func (s *Scheduler) parseRRule(schedule *models.Schedule) (*rrule.Set, error) {
	// Parse the RRule JSON
	var rruleData models.RRule
	if err := json.Unmarshal([]byte(schedule.RecurrenceJSON), &rruleData); err != nil {
		return nil, err
	}

	// Build rrule options
	dtstart := time.Now()
	if schedule.DTStart != nil {
		dtstart = *schedule.DTStart
	}

	// Build the RRule string from JSON
	rruleStr := s.buildRRuleString(rruleData, dtstart)

	// Parse the RRule
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

// buildRRuleString builds an RFC 5545 RRule string from RRule data
func (s *Scheduler) buildRRuleString(rruleData models.RRule, dtstart time.Time) string {
	// Simple implementation - can be enhanced
	rruleStr := "DTSTART:" + dtstart.Format("20060102T150405Z") + "\nRRULE:"

	if rruleData.Freq != "" {
		rruleStr += "FREQ=" + rruleData.Freq
	}

	if rruleData.Interval > 0 {
		rruleStr += ";INTERVAL=" + string(rune(rruleData.Interval+'0'))
	}

	// Add other parameters as needed
	// This is a simplified version - production code would need more complete parsing

	return rruleStr
}

// dispatchScheduleEvent creates and dispatches a schedule triggered event
func (s *Scheduler) dispatchScheduleEvent(schedule *models.Schedule) {
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

	// Create the dispatch event
	event := &pb.DispatchEvent{
		EventId:   uuid.New().String(),
		EventType: pb.EventType_EVENT_TYPE_SCHEDULE_TRIGGERED,
		Timestamp: timestamppb.Now(),
		Payload: &pb.DispatchEvent_ScheduleTriggered{
			ScheduleTriggered: &pb.ScheduleTriggeredEvent{
				ScheduleId:    schedule.ScheduleID,
				RoutineId:     routine.ID,
				RoutineName:   routine.Name,
				ScheduledTime: timestamppb.Now(),
				ActionIds:     routine.ActionIDs,
			},
		},
	}

	// Broadcast the event to subscribed clients
	s.eventHub.Broadcast(profileID, event)

	// Update last execution time
	if err := s.db.UpdateLastExecution(schedule.ScheduleID, time.Now()); err != nil {
		s.logger.Error("Failed to update last execution time",
			zap.String("schedule_id", schedule.ScheduleID),
			zap.Error(err))
	}

	s.logger.Info("Dispatched schedule event",
		zap.String("schedule_id", schedule.ScheduleID),
		zap.String("routine_id", routine.ID),
		zap.String("routine_name", routine.Name),
		zap.String("profile_id", profileID))
}