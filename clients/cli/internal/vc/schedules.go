package vc

import (
	"context"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Paging bounds shared by every list wrapper. listPageSize is large because
// these are loopback RPCs against SQLite — the round trip costs more than
// the rows — and maxListPages exists only so a server with a broken cursor
// cannot spin the CLI forever. Hitting the cap silently truncates, which is
// the lesser evil against a command that never returns.
const (
	listPageSize = 200
	maxListPages = 100
)

// ScheduleFilter narrows ListSchedules. It mirrors ListSchedulesRequest,
// which filters by routine — there is no profile filter on this RPC, and
// inventing one here would only move the disappointment later.
type ScheduleFilter struct {
	RoutineID   string
	EnabledOnly bool
}

// ListSchedules returns every schedule matching the filter, following page
// tokens to the end. A CLI that showed page one and said nothing would be
// worse than one that failed.
func (s *Session) ListSchedules(ctx context.Context, f ScheduleFilter) ([]Schedule, error) {
	return eachPage(func(token string) ([]Schedule, string, error) {
		resp, err := s.schedule.ListSchedules(ctx, &pb.ListSchedulesRequest{
			RoutineId:   f.RoutineID,
			EnabledOnly: f.EnabledOnly,
			PageSize:    listPageSize,
			PageToken:   token,
		})
		if err != nil {
			return nil, "", s.rpcErr("routine", f.RoutineID, err)
		}
		out := make([]Schedule, 0, len(resp.GetSchedules()))
		for _, p := range resp.GetSchedules() {
			out = append(out, scheduleFromProto(p))
		}
		return out, resp.GetNextPageToken(), nil
	})
}

// GetSchedule returns one schedule with its action list resolved. This is
// the only place that fan-out is acceptable: a list view doing the same
// would be one RPC per row.
func (s *Session) GetSchedule(ctx context.Context, id string) (Schedule, error) {
	if id == "" {
		return Schedule{}, Usagef("schedule id required")
	}
	p, err := s.schedule.GetSchedule(ctx, &pb.GetScheduleRequest{ScheduleId: id})
	if err != nil {
		return Schedule{}, s.rpcErr("schedule", id, err)
	}
	sc := scheduleFromProto(p)
	sc.Actions = s.scheduleActions(ctx, id)
	return sc, nil
}

// scheduleActions resolves the join table into full actions, degrading to
// bare ids when the action rows cannot be read. The join is the authority
// on what a schedule runs, so losing the names must not lose the list.
func (s *Session) scheduleActions(ctx context.Context, id string) []Action {
	resp, err := s.schedule.GetScheduleActions(ctx, &pb.GetScheduleActionsRequest{ScheduleId: id})
	if err != nil {
		return nil
	}
	ids := resp.GetActionIds()
	out := make([]Action, 0, len(ids))
	for i, aid := range ids {
		a := Action{ID: aid}
		if full, err := s.action.GetAction(ctx, &pb.GetActionRequest{Id: aid}); err == nil {
			a = actionFromProto(full)
		}
		// The join table's order is the execution order, and it exists
		// nowhere on the Action message itself.
		a.Order = int32(i)
		out = append(out, a)
	}
	return out
}

// PauseSchedule stops a schedule indefinitely. The timed variant of the RPC
// is deliberately not exposed: "pause until" is a decision the scheduler
// owns and a flag nobody asked this client for.
func (s *Session) PauseSchedule(ctx context.Context, id string) error {
	if id == "" {
		return Usagef("schedule id required")
	}
	if _, err := s.schedule.PauseSchedule(ctx, &pb.PauseScheduleRequest{ScheduleId: id}); err != nil {
		return s.rpcErr("schedule", id, err)
	}
	return nil
}

func (s *Session) ResumeSchedule(ctx context.Context, id string) error {
	if id == "" {
		return Usagef("schedule id required")
	}
	if _, err := s.schedule.ResumeSchedule(ctx, &pb.ResumeScheduleRequest{ScheduleId: id}); err != nil {
		return s.rpcErr("schedule", id, err)
	}
	return nil
}

// PauseAllSchedules is the panic button. profile_id is left empty, which the
// server reads as every profile: a CLI user who types "pause all" means all.
func (s *Session) PauseAllSchedules(ctx context.Context) error {
	if _, err := s.schedule.PauseAllSchedules(ctx, &pb.PauseAllSchedulesRequest{}); err != nil {
		return s.rpcErr("schedules", "", err)
	}
	return nil
}

func (s *Session) ResumeAllSchedules(ctx context.Context) error {
	if _, err := s.schedule.ResumeAllSchedules(ctx, &pb.ResumeAllSchedulesRequest{}); err != nil {
		return s.rpcErr("schedules", "", err)
	}
	return nil
}

func scheduleFromProto(p *pb.Schedule) Schedule {
	return Schedule{
		ID:            p.GetScheduleId(),
		ProfileID:     p.GetProfileId(),
		RoutineID:     p.GetRoutineId(),
		Name:          p.GetName(),
		RRule:         p.GetRrule(),
		Timezone:      p.GetScheduleTimezone(),
		Notes:         p.GetNotes(),
		Enabled:       p.GetEnabled(),
		Type:          scheduleTypeString(p.GetScheduleType()),
		DTStart:       protoTime(p.GetDtstart()),
		LastExecution: protoTime(p.GetLastExecution()),
		NextExecution: protoTime(p.GetNextExecution()),
		CreatedAt:     protoTime(p.GetCreatedAt()),
		UpdatedAt:     protoTime(p.GetUpdatedAt()),
	}
}

// scheduleTypeString renders the enum the way the rest of this client
// renders enums: as a lowercase string, so a JSON consumer never has to
// read a .proto to learn what 2 means. Unspecified becomes empty rather
// than a made-up name.
func scheduleTypeString(t pb.ScheduleType) string {
	switch t {
	case pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT:
		return "one_shot"
	case pb.ScheduleType_SCHEDULE_TYPE_RECURRING:
		return "recurring"
	default:
		return ""
	}
}

// protoTime converts a proto timestamp, mapping both an absent message and a
// zero-valued one to nil. The distinction is load-bearing: "never run" and
// "ran at the unix epoch" have to render differently, and the backend writes
// an unset SQLite column as the zero timestamp often enough that treating
// only nil as unset would print 1970 in front of users.
func protoTime(ts *timestamppb.Timestamp) *time.Time {
	if ts == nil || (ts.GetSeconds() == 0 && ts.GetNanos() == 0) {
		return nil
	}
	t := ts.AsTime().UTC()
	return &t
}

// eachPage drains a paginated RPC. It stops on a repeated page token as well
// as an empty one, because a server that keeps returning its own cursor is a
// bug that would otherwise present as a hung command.
func eachPage[T any](fetch func(token string) ([]T, string, error)) ([]T, error) {
	var (
		out  []T
		seen = map[string]bool{}
		tok  string
	)
	for range maxListPages {
		items, next, err := fetch(tok)
		if err != nil {
			return nil, err
		}
		out = append(out, items...)
		if next == "" || seen[next] {
			return out, nil
		}
		seen[next] = true
		tok = next
	}
	return out, nil
}

// rpcErr converts a gRPC failure into an error carrying the exit code the
// process should use. Only NotFound and Unavailable are distinguished:
// inventing finer mappings would hand scripts exit codes that do not mean
// what they claim.
func (s *Session) rpcErr(kind, id string, err error) error {
	st, ok := status.FromError(err)
	if !ok {
		return Errorf("%s: %v", kind, err)
	}
	switch st.Code() {
	case codes.NotFound:
		// Without an id there is nothing to name, and "\"\" not found" is
		// worse than the server's own message.
		if id != "" {
			return NotFound(kind, id)
		}
	case codes.Unavailable:
		return Unreachable(s.addr, err)
	}
	return Errorf("%s: %s", kind, st.Message())
}
