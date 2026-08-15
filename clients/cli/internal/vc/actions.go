package vc

import (
	"context"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
)

// ListActions returns every action for a profile, following page tokens to
// the end. The type filter is deliberately not exposed: filtering a list
// this small is the shell's job, and `--type` would be one more flag whose
// legal values live in a .proto the user cannot see.
func (s *Session) ListActions(ctx context.Context, profileID string) ([]Action, error) {
	return eachPage(func(token string) ([]Action, string, error) {
		resp, err := s.action.ListActions(ctx, &pb.ListActionsRequest{
			ProfileId: profileID,
			PageSize:  listPageSize,
			PageToken: token,
		})
		if err != nil {
			return nil, "", s.rpcErr("profile", profileID, err)
		}
		out := make([]Action, 0, len(resp.GetActions()))
		for _, p := range resp.GetActions() {
			out = append(out, actionFromProto(p))
		}
		return out, resp.GetNextPageToken(), nil
	})
}

func (s *Session) GetAction(ctx context.Context, id string) (Action, error) {
	if id == "" {
		return Action{}, Usagef("action id required")
	}
	p, err := s.action.GetAction(ctx, &pb.GetActionRequest{Id: id})
	if err != nil {
		return Action{}, s.rpcErr("action", id, err)
	}
	return actionFromProto(p), nil
}

// RunAction executes one action and returns its result string.
//
// An action that reports success=false is an RPC that succeeded and a
// command that failed. Returning the result unchanged would exit 0 on a
// notification that never fired, so the failure is promoted to an error.
func (s *Session) RunAction(ctx context.Context, id string) (string, error) {
	if id == "" {
		return "", Usagef("action id required")
	}
	resp, err := s.action.ExecuteAction(ctx, &pb.ExecuteActionRequest{ActionId: id})
	if err != nil {
		return "", s.rpcErr("action", id, err)
	}
	if !resp.GetSuccess() {
		msg := resp.GetErrorMessage()
		if msg == "" {
			msg = "action reported failure without a message"
		}
		return "", Errorf("run action %s: %s", id, msg)
	}
	return resp.GetResult(), nil
}

// ActionTypes lists the action types core will accept, as the same lowercase
// strings Action.Type carries. The RPC also returns human names and
// parameter schemas; this client returns the identifiers, because the
// identifiers are what a caller passes back in.
func (s *Session) ActionTypes(ctx context.Context) ([]string, error) {
	resp, err := s.action.ListActionTypes(ctx, &pb.ListActionTypesRequest{})
	if err != nil {
		return nil, s.rpcErr("action types", "", err)
	}
	out := make([]string, 0, len(resp.GetActionTypes()))
	for _, t := range resp.GetActionTypes() {
		if name := actionTypeString(t.GetType()); name != "" {
			out = append(out, name)
		}
	}
	return out, nil
}

func actionFromProto(p *pb.Action) Action {
	return Action{
		ID:        p.GetId(),
		ProfileID: p.GetProfileId(),
		Name:      p.GetName(),
		Type:      actionTypeString(p.GetType()),
		Params:    p.GetParameters(),
		Notes:     p.GetDescription(),
		Enabled:   p.GetEnabled(),
	}
}

// actionTypeString renders the enum as the string the database and the REST
// surface already use (models.ActionType), so the same word means the same
// thing whichever way a user reaches VibeCare. Unspecified becomes empty
// rather than a plausible-looking lie.
func actionTypeString(t pb.ActionType) string {
	switch t {
	case pb.ActionType_ACTION_TYPE_NOTIFICATION:
		return "notification"
	case pb.ActionType_ACTION_TYPE_OPEN_LINK:
		return "open_link"
	case pb.ActionType_ACTION_TYPE_SEND_EMAIL:
		return "send_email"
	case pb.ActionType_ACTION_TYPE_RUN_SCRIPT:
		return "run_script"
	case pb.ActionType_ACTION_TYPE_PLAY_SOUND:
		return "play_sound"
	case pb.ActionType_ACTION_TYPE_SYSTEM_COMMAND:
		return "system_command"
	case pb.ActionType_ACTION_TYPE_API_CALL:
		return "api_call"
	case pb.ActionType_ACTION_TYPE_LOG_ENTRY:
		return "log_entry"
	default:
		return ""
	}
}
