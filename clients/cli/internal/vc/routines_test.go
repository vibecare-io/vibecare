package vc

import (
	"context"
	"testing"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestListRoutinesFollowsPagination(t *testing.T) {
	sess, f := newTestServer(t)

	var sawProfile string
	f.routines.listFn = func(_ context.Context, r *pb.ListRoutinesRequest) (*pb.ListRoutinesResponse, error) {
		sawProfile = r.GetProfileId()
		switch r.GetPageToken() {
		case "":
			return &pb.ListRoutinesResponse{
				Routines:      []*pb.Routine{{Id: "r1", Name: "wake up"}},
				NextPageToken: "page-2",
			}, nil
		case "page-2":
			return &pb.ListRoutinesResponse{
				Routines: []*pb.Routine{{Id: "r2", Name: "wind down"}},
			}, nil
		}
		return nil, status.Errorf(codes.InvalidArgument, "unexpected page token %q", r.GetPageToken())
	}

	got, err := sess.ListRoutines(testCtx(t), "p1")
	if err != nil {
		t.Fatalf("ListRoutines: %v", err)
	}
	if len(got) != 2 || got[0].ID != "r1" || got[1].ID != "r2" {
		t.Fatalf("want both pages, got %+v", got)
	}
	if sawProfile != "p1" {
		t.Fatalf("profile filter = %q, want p1", sawProfile)
	}
}

func TestGetRoutineIncludesActions(t *testing.T) {
	sess, f := newTestServer(t)

	f.routines.getFn = func(_ context.Context, r *pb.GetRoutineRequest) (*pb.GetRoutineResponse, error) {
		return &pb.GetRoutineResponse{
			Routine: &pb.Routine{Id: r.GetId(), Name: "wake up", Description: "gentle", Enabled: true},
			Actions: []*pb.Action{{Id: "a1", Name: "chime", Type: pb.ActionType_ACTION_TYPE_PLAY_SOUND}},
		}, nil
	}

	got, err := sess.GetRoutine(testCtx(t), "r1")
	if err != nil {
		t.Fatalf("GetRoutine: %v", err)
	}
	if got.Notes != "gentle" {
		t.Fatalf("notes = %q, want the proto description", got.Notes)
	}
	if len(got.Actions) != 1 || got.Actions[0].Type != "play_sound" {
		t.Fatalf("actions = %+v", got.Actions)
	}
	if got.CreatedAt != nil {
		t.Fatalf("unset created_at must stay nil, got %v", *got.CreatedAt)
	}
}

func TestGetRoutineNotFound(t *testing.T) {
	sess, f := newTestServer(t)

	f.routines.getFn = func(context.Context, *pb.GetRoutineRequest) (*pb.GetRoutineResponse, error) {
		return nil, status.Error(codes.NotFound, "no such routine")
	}
	if _, err := sess.GetRoutine(testCtx(t), "gone"); ExitCode(err) != ExitNotFound {
		t.Fatalf("exit code = %d, want %d", ExitCode(err), ExitNotFound)
	}
}

func TestRunRoutineReturnsExecutionLog(t *testing.T) {
	sess, f := newTestServer(t)

	ran := time.Date(2026, 8, 14, 7, 0, 0, 0, time.UTC)
	f.routines.executeFn = func(_ context.Context, r *pb.ExecuteRoutineRequest) (*pb.ExecutionLog, error) {
		return &pb.ExecutionLog{
			LogId:         42,
			RoutineId:     r.GetRoutineId(),
			Timestamp:     timestamppb.New(ran),
			Completed:     true,
			ActionResults: map[string]string{"a1": "ok"},
		}, nil
	}

	got, err := sess.RunRoutine(testCtx(t), "r1")
	if err != nil {
		t.Fatalf("RunRoutine: %v", err)
	}
	if got.LogID != 42 || !got.Completed || got.Results["a1"] != "ok" {
		t.Fatalf("log = %+v", got)
	}
	if got.Timestamp == nil || !got.Timestamp.Equal(ran) {
		t.Fatalf("timestamp = %v, want %v", got.Timestamp, ran)
	}
}

func TestRoutineLogsUnsetTimestampStaysNil(t *testing.T) {
	sess, f := newTestServer(t)

	f.routines.logsFn = func(_ context.Context, r *pb.GetExecutionLogsRequest) (*pb.GetExecutionLogsResponse, error) {
		if r.GetRoutineId() != "r1" {
			return nil, status.Error(codes.InvalidArgument, "wrong routine")
		}
		return &pb.GetExecutionLogsResponse{Logs: []*pb.ExecutionLog{
			{LogId: 1, RoutineId: "r1"},
		}}, nil
	}

	got, err := sess.RoutineLogs(testCtx(t), "r1")
	if err != nil {
		t.Fatalf("RoutineLogs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 log, got %d", len(got))
	}
	if got[0].Timestamp != nil {
		t.Fatalf("unset timestamp must stay nil, got %v", *got[0].Timestamp)
	}
}

// --- actions ---------------------------------------------------------------

func TestListActionsFollowsPagination(t *testing.T) {
	sess, f := newTestServer(t)

	f.actions.listFn = func(_ context.Context, r *pb.ListActionsRequest) (*pb.ListActionsResponse, error) {
		switch r.GetPageToken() {
		case "":
			return &pb.ListActionsResponse{
				Actions: []*pb.Action{{
					Id: "a1", Name: "notify", Type: pb.ActionType_ACTION_TYPE_NOTIFICATION,
					Parameters: map[string]string{"title": "hi"}, Enabled: true,
				}},
				NextPageToken: "page-2",
			}, nil
		case "page-2":
			return &pb.ListActionsResponse{
				Actions: []*pb.Action{{Id: "a2", Name: "open", Type: pb.ActionType_ACTION_TYPE_OPEN_LINK}},
			}, nil
		}
		return nil, status.Errorf(codes.InvalidArgument, "unexpected page token %q", r.GetPageToken())
	}

	got, err := sess.ListActions(testCtx(t), "p1")
	if err != nil {
		t.Fatalf("ListActions: %v", err)
	}
	if len(got) != 2 || got[0].ID != "a1" || got[1].ID != "a2" {
		t.Fatalf("want both pages, got %+v", got)
	}
	if got[0].Type != "notification" || got[1].Type != "open_link" {
		t.Fatalf("types = %q, %q", got[0].Type, got[1].Type)
	}
	if got[0].Params["title"] != "hi" {
		t.Fatalf("params = %+v", got[0].Params)
	}
}

func TestGetActionNotFound(t *testing.T) {
	sess, f := newTestServer(t)

	f.actions.getFn = func(context.Context, *pb.GetActionRequest) (*pb.Action, error) {
		return nil, status.Error(codes.NotFound, "no such action")
	}
	if _, err := sess.GetAction(testCtx(t), "gone"); ExitCode(err) != ExitNotFound {
		t.Fatalf("exit code = %d, want %d", ExitCode(err), ExitNotFound)
	}
}

func TestRunAction(t *testing.T) {
	sess, f := newTestServer(t)

	f.actions.executeFn = func(_ context.Context, r *pb.ExecuteActionRequest) (*pb.ExecuteActionResponse, error) {
		if r.GetActionId() == "bad" {
			return &pb.ExecuteActionResponse{Success: false, ErrorMessage: "smtp refused"}, nil
		}
		return &pb.ExecuteActionResponse{Success: true, Result: "delivered"}, nil
	}

	ctx := testCtx(t)
	got, err := sess.RunAction(ctx, "a1")
	if err != nil {
		t.Fatalf("RunAction: %v", err)
	}
	if got != "delivered" {
		t.Fatalf("result = %q", got)
	}

	// A refused action is an RPC that succeeded and a command that failed;
	// the exit code has to reflect the command.
	if _, err := sess.RunAction(ctx, "bad"); err == nil {
		t.Fatal("want an error for an unsuccessful action")
	} else if ExitCode(err) != ExitError {
		t.Fatalf("exit code = %d, want %d", ExitCode(err), ExitError)
	}
}

func TestActionTypes(t *testing.T) {
	sess, f := newTestServer(t)

	f.actions.typesFn = func(context.Context, *pb.ListActionTypesRequest) (*pb.ListActionTypesResponse, error) {
		return &pb.ListActionTypesResponse{ActionTypes: []*pb.ActionTypeInfo{
			{Type: pb.ActionType_ACTION_TYPE_NOTIFICATION, Name: "Notification"},
			{Type: pb.ActionType_ACTION_TYPE_OPEN_LINK, Name: "Open Link"},
		}}, nil
	}

	got, err := sess.ActionTypes(testCtx(t))
	if err != nil {
		t.Fatalf("ActionTypes: %v", err)
	}
	if len(got) != 2 || got[0] != "notification" || got[1] != "open_link" {
		t.Fatalf("types = %+v", got)
	}
}
