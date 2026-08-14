package kernel

import (
	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

// ShellService is the entire client-facing plugin contract: a roster
// stream and an alert stream. It is frozen at two RPCs while plugins are
// added indefinitely, because clients contain no plugin-specific code —
// a client knows only "a URL", never a schema.
type ShellService struct {
	clientv1.UnimplementedShellServer

	reg     *Registry
	intents *Intents
	baseURL func() string
	token   string
}

func NewShellService(reg *Registry, in *Intents, baseURL func() string, token string) *ShellService {
	return &ShellService{reg: reg, intents: in, baseURL: baseURL, token: token}
}

// Plugins streams the roster: the current one immediately, then the whole
// list again on any state change. The roster is small and changes rarely,
// so there is no need for deltas.
func (s *ShellService) Plugins(_ *emptypb.Empty, stream clientv1.Shell_PluginsServer) error {
	updates, cancel := s.reg.Watch()
	defer cancel()

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case snap, ok := <-updates:
			if !ok {
				return nil
			}
			if err := stream.Send(s.toPluginList(snap)); err != nil {
				return err
			}
		}
	}
}

func (s *ShellService) toPluginList(snap []PluginStat) *clientv1.PluginList {
	out := &clientv1.PluginList{BaseUrl: s.baseURL(), Token: s.token}
	for _, p := range snap {
		// A headless plugin gets no tab — that is what ui: none means.
		if p.UI == "none" {
			continue
		}
		out.Plugins = append(out.Plugins, &clientv1.PluginInfo{
			Id:     p.ID,
			Name:   p.Name,
			Icon:   p.Icon,
			Path:   p.Path,
			State:  toProtoState(p.State),
			Detail: p.Detail,
		})
	}
	return out
}

func toProtoState(s State) clientv1.State {
	switch s {
	case StateUp:
		return clientv1.State_UP
	case StateDegraded:
		return clientv1.State_DEGRADED
	case StateDown:
		return clientv1.State_DOWN
	case StateFailed:
		return clientv1.State_FAILED
	default:
		return clientv1.State_STARTING
	}
}

// Intents streams alerts. They are transient and never retained.
func (s *ShellService) Intents(_ *emptypb.Empty, stream clientv1.Shell_IntentsServer) error {
	alerts, cancel := s.intents.Subscribe()
	defer cancel()

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case a, ok := <-alerts:
			if !ok {
				return nil
			}
			err := stream.Send(&clientv1.UIIntent{K: &clientv1.UIIntent_Alert{Alert: a}})
			if err != nil {
				return err
			}
		}
	}
}
