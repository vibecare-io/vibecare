package vc

import (
	"context"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
)

// executionLogLimit bounds RoutineLogs. The RPC has no cursor, so the only
// way to keep a chatty routine from returning its whole history is to ask
// for less of it; a client showing recent runs never wants more.
const executionLogLimit = 200

// ListRoutines returns every routine for a profile, following page tokens to
// the end. An empty profileID means whatever the server treats as the
// default — this client does not guess one.
func (s *Session) ListRoutines(ctx context.Context, profileID string) ([]Routine, error) {
	return eachPage(func(token string) ([]Routine, string, error) {
		resp, err := s.routine.ListRoutines(ctx, &pb.ListRoutinesRequest{
			ProfileId: profileID,
			PageSize:  listPageSize,
			PageToken: token,
		})
		if err != nil {
			return nil, "", s.rpcErr("profile", profileID, err)
		}
		out := make([]Routine, 0, len(resp.GetRoutines()))
		for _, p := range resp.GetRoutines() {
			out = append(out, routineFromProto(p))
		}
		return out, resp.GetNextPageToken(), nil
	})
}

// GetRoutine returns one routine with its actions. Unlike GetSchedule this
// needs no second call: GetRoutineResponse already carries them.
func (s *Session) GetRoutine(ctx context.Context, id string) (Routine, error) {
	if id == "" {
		return Routine{}, Usagef("routine id required")
	}
	resp, err := s.routine.GetRoutine(ctx, &pb.GetRoutineRequest{Id: id})
	if err != nil {
		return Routine{}, s.rpcErr("routine", id, err)
	}
	r := routineFromProto(resp.GetRoutine())
	for _, a := range resp.GetActions() {
		r.Actions = append(r.Actions, actionFromProto(a))
	}
	return r, nil
}

// RunRoutine executes a routine now. Force is set because a human typing
// `vibecare routines run` has already decided; refusing on the grounds that
// it is not due would be answering a question nobody asked.
func (s *Session) RunRoutine(ctx context.Context, id string) (ExecutionLog, error) {
	if id == "" {
		return ExecutionLog{}, Usagef("routine id required")
	}
	log, err := s.routine.ExecuteRoutine(ctx, &pb.ExecuteRoutineRequest{
		RoutineId: id,
		Force:     true,
		Notes:     "run from vibecare cli",
	})
	if err != nil {
		return ExecutionLog{}, s.rpcErr("routine", id, err)
	}
	return executionLogFromProto(log), nil
}

// RoutineLogs returns recent execution logs for a routine, newest-first or
// not depending on the server — this client preserves the order it is given
// rather than imposing one the backend may already have chosen.
func (s *Session) RoutineLogs(ctx context.Context, id string) ([]ExecutionLog, error) {
	if id == "" {
		return nil, Usagef("routine id required")
	}
	resp, err := s.routine.GetExecutionLogs(ctx, &pb.GetExecutionLogsRequest{
		RoutineId: id,
		Limit:     executionLogLimit,
	})
	if err != nil {
		return nil, s.rpcErr("routine", id, err)
	}
	out := make([]ExecutionLog, 0, len(resp.GetLogs()))
	for _, l := range resp.GetLogs() {
		out = append(out, executionLogFromProto(l))
	}
	return out, nil
}

func routineFromProto(p *pb.Routine) Routine {
	return Routine{
		ID:        p.GetId(),
		ProfileID: p.GetProfileId(),
		Name:      p.GetName(),
		// The proto calls it description; every surface a user reads calls
		// it notes, and types.go is the contract.
		Notes:     p.GetDescription(),
		Enabled:   p.GetEnabled(),
		CreatedAt: protoTime(p.GetCreatedAt()),
		UpdatedAt: protoTime(p.GetUpdatedAt()),
	}
}

func executionLogFromProto(p *pb.ExecutionLog) ExecutionLog {
	return ExecutionLog{
		LogID:     p.GetLogId(),
		RoutineID: p.GetRoutineId(),
		Timestamp: protoTime(p.GetTimestamp()),
		Completed: p.GetCompleted(),
		Notes:     p.GetNotes(),
		Results:   p.GetActionResults(),
	}
}
