package vc

import (
	"context"
	"testing"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestListSchedulesFollowsPagination(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.listFn = func(_ context.Context, r *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
		switch r.GetPageToken() {
		case "":
			return &pb.ListSchedulesResponse{
				Schedules:     []*pb.Schedule{{ScheduleId: "s1", Name: "morning"}},
				NextPageToken: "page-2",
			}, nil
		case "page-2":
			return &pb.ListSchedulesResponse{
				Schedules: []*pb.Schedule{{ScheduleId: "s2", Name: "evening"}},
			}, nil
		}
		return nil, status.Errorf(codes.InvalidArgument, "unexpected page token %q", r.GetPageToken())
	}

	got, err := sess.ListSchedules(testCtx(t), ScheduleFilter{RoutineID: "r1", EnabledOnly: true})
	if err != nil {
		t.Fatalf("ListSchedules: %v", err)
	}
	if len(got) != 2 || got[0].ID != "s1" || got[1].ID != "s2" {
		t.Fatalf("want both pages, got %+v", got)
	}
	if r := f.schedules.lastListReq; r.GetRoutineId() != "r1" || !r.GetEnabledOnly() {
		t.Fatalf("filter not forwarded: %+v", r)
	}
}

// A server that keeps handing back the same token would otherwise spin
// forever inside a CLI that looks hung.
func TestListSchedulesStopsOnRepeatedPageToken(t *testing.T) {
	sess, f := newTestServer(t)

	calls := 0
	f.schedules.listFn = func(context.Context, *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
		calls++
		return &pb.ListSchedulesResponse{
			Schedules:     []*pb.Schedule{{ScheduleId: "s1"}},
			NextPageToken: "stuck",
		}, nil
	}

	if _, err := sess.ListSchedules(testCtx(t), ScheduleFilter{}); err != nil {
		t.Fatalf("ListSchedules: %v", err)
	}
	if calls > maxListPages {
		t.Fatalf("followed %d pages, cap is %d", calls, maxListPages)
	}
}

func TestListSchedulesLeavesActionsEmpty(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.listFn = func(context.Context, *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
		return &pb.ListSchedulesResponse{Schedules: []*pb.Schedule{{ScheduleId: "s1"}}}, nil
	}
	// Unprogrammed: a call here fails the RPC, which is exactly how a
	// per-row fan-out would announce itself.
	f.schedules.actionsFn = nil

	got, err := sess.ListSchedules(testCtx(t), ScheduleFilter{})
	if err != nil {
		t.Fatalf("ListSchedules: %v", err)
	}
	if len(got[0].Actions) != 0 {
		t.Fatalf("list must not hydrate actions, got %+v", got[0].Actions)
	}
}

func TestGetSchedulePopulatesActions(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.getFn = func(_ context.Context, r *pb.GetScheduleRequest) (*pb.Schedule, error) {
		return &pb.Schedule{ScheduleId: r.GetScheduleId(), Name: "morning"}, nil
	}
	f.schedules.actionsFn = func(context.Context, *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error) {
		return &pb.GetScheduleActionsResponse{ActionIds: []string{"a1", "a2"}}, nil
	}
	f.actions.getFn = func(_ context.Context, r *pb.GetActionRequest) (*pb.Action, error) {
		return &pb.Action{Id: r.GetId(), Name: "notify " + r.GetId(), Type: pb.ActionType_ACTION_TYPE_NOTIFICATION}, nil
	}

	got, err := sess.GetSchedule(testCtx(t), "s1")
	if err != nil {
		t.Fatalf("GetSchedule: %v", err)
	}
	if len(got.Actions) != 2 {
		t.Fatalf("want 2 actions, got %+v", got.Actions)
	}
	if got.Actions[0].ID != "a1" || got.Actions[0].Name != "notify a1" {
		t.Fatalf("action not hydrated: %+v", got.Actions[0])
	}
	if got.Actions[1].Order != 1 {
		t.Fatalf("want join order preserved, got %d", got.Actions[1].Order)
	}
}

// The join table is the authority on which actions a schedule runs, so a
// schedule still lists them even when the action rows cannot be read.
func TestGetScheduleKeepsActionIDsWhenHydrationFails(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.getFn = func(_ context.Context, r *pb.GetScheduleRequest) (*pb.Schedule, error) {
		return &pb.Schedule{ScheduleId: r.GetScheduleId()}, nil
	}
	f.schedules.actionsFn = func(context.Context, *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error) {
		return &pb.GetScheduleActionsResponse{ActionIds: []string{"a1"}}, nil
	}
	f.actions.getFn = nil // Unimplemented

	got, err := sess.GetSchedule(testCtx(t), "s1")
	if err != nil {
		t.Fatalf("GetSchedule: %v", err)
	}
	if len(got.Actions) != 1 || got.Actions[0].ID != "a1" {
		t.Fatalf("want bare action id, got %+v", got.Actions)
	}
}

func TestScheduleTimestampsDistinguishUnsetFromEpoch(t *testing.T) {
	sess, f := newTestServer(t)

	when := time.Date(2026, 8, 14, 9, 30, 0, 0, time.UTC)
	f.schedules.getFn = func(_ context.Context, r *pb.GetScheduleRequest) (*pb.Schedule, error) {
		return &pb.Schedule{
			ScheduleId: r.GetScheduleId(),
			Dtstart:    timestamppb.New(when),
			// last_execution unset: never run.
			CreatedAt: &timestamppb.Timestamp{}, // zero on the wire, also "unset"
		}, nil
	}
	f.schedules.actionsFn = func(context.Context, *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error) {
		return &pb.GetScheduleActionsResponse{}, nil
	}

	got, err := sess.GetSchedule(testCtx(t), "s1")
	if err != nil {
		t.Fatalf("GetSchedule: %v", err)
	}
	if got.LastExecution != nil {
		t.Fatalf("nil proto timestamp must stay nil, got %v", *got.LastExecution)
	}
	if got.CreatedAt != nil {
		t.Fatalf("zero proto timestamp must stay nil, got %v", *got.CreatedAt)
	}
	if got.DTStart == nil || !got.DTStart.Equal(when) {
		t.Fatalf("dtstart = %v, want %v", got.DTStart, when)
	}
}

func TestGetScheduleNotFound(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.getFn = func(context.Context, *pb.GetScheduleRequest) (*pb.Schedule, error) {
		return nil, status.Error(codes.NotFound, "schedule not found")
	}

	_, err := sess.GetSchedule(testCtx(t), "nope")
	if err == nil {
		t.Fatal("want an error")
	}
	if code := ExitCode(err); code != ExitNotFound {
		t.Fatalf("exit code = %d, want %d (%v)", code, ExitNotFound, err)
	}
}

func TestPauseAndResumeSchedule(t *testing.T) {
	sess, f := newTestServer(t)

	var paused, resumed string
	f.schedules.pauseFn = func(_ context.Context, r *pb.PauseScheduleRequest) (*pb.Schedule, error) {
		paused = r.GetScheduleId()
		return &pb.Schedule{ScheduleId: r.GetScheduleId()}, nil
	}
	f.schedules.resumeFn = func(_ context.Context, r *pb.ResumeScheduleRequest) (*pb.Schedule, error) {
		resumed = r.GetScheduleId()
		return &pb.Schedule{ScheduleId: r.GetScheduleId()}, nil
	}

	ctx := testCtx(t)
	if err := sess.PauseSchedule(ctx, "s1"); err != nil {
		t.Fatalf("PauseSchedule: %v", err)
	}
	if err := sess.ResumeSchedule(ctx, "s1"); err != nil {
		t.Fatalf("ResumeSchedule: %v", err)
	}
	if paused != "s1" || resumed != "s1" {
		t.Fatalf("paused=%q resumed=%q", paused, resumed)
	}

	if err := sess.PauseSchedule(ctx, ""); ExitCode(err) != ExitUsage {
		t.Fatalf("empty id should be a usage error, got %v", err)
	}
}

func TestPauseScheduleNotFound(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.pauseFn = func(context.Context, *pb.PauseScheduleRequest) (*pb.Schedule, error) {
		return nil, status.Error(codes.NotFound, "no such schedule")
	}
	if err := sess.PauseSchedule(testCtx(t), "gone"); ExitCode(err) != ExitNotFound {
		t.Fatalf("exit code = %d, want %d (%v)", ExitCode(err), ExitNotFound, err)
	}
}

func TestPauseAndResumeAllSchedules(t *testing.T) {
	sess, f := newTestServer(t)

	calls := 0
	f.schedules.pauseAllFn = func(context.Context, *pb.PauseAllSchedulesRequest) (*emptypb.Empty, error) {
		calls++
		return &emptypb.Empty{}, nil
	}
	f.schedules.resumeAllFn = func(context.Context, *pb.ResumeAllSchedulesRequest) (*emptypb.Empty, error) {
		calls++
		return &emptypb.Empty{}, nil
	}

	ctx := testCtx(t)
	if err := sess.PauseAllSchedules(ctx); err != nil {
		t.Fatalf("PauseAllSchedules: %v", err)
	}
	if err := sess.ResumeAllSchedules(ctx); err != nil {
		t.Fatalf("ResumeAllSchedules: %v", err)
	}
	if calls != 2 {
		t.Fatalf("calls = %d, want 2", calls)
	}
}

func TestScheduleTypeIsAString(t *testing.T) {
	sess, f := newTestServer(t)

	f.schedules.listFn = func(context.Context, *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
		return &pb.ListSchedulesResponse{Schedules: []*pb.Schedule{
			{ScheduleId: "s1", ScheduleType: pb.ScheduleType_SCHEDULE_TYPE_RECURRING},
			{ScheduleId: "s2", ScheduleType: pb.ScheduleType_SCHEDULE_TYPE_ONE_SHOT},
			{ScheduleId: "s3"},
		}}, nil
	}

	got, err := sess.ListSchedules(testCtx(t), ScheduleFilter{})
	if err != nil {
		t.Fatalf("ListSchedules: %v", err)
	}
	want := []string{"recurring", "one_shot", ""}
	for i, w := range want {
		if got[i].Type != w {
			t.Fatalf("schedule %d type = %q, want %q", i, got[i].Type, w)
		}
	}
}
