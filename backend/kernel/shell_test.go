package kernel

import (
	"testing"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"go.uber.org/zap"
)

func TestToPluginListCarriesOriginAndToken(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Icon: "circle", Exec: "./a", UI: "webview"})
	s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "http://127.0.0.1:52341" }, "tok123")

	got := s.toPluginList(reg.Snapshot())
	if got.BaseUrl != "http://127.0.0.1:52341" || got.Token != "tok123" {
		t.Fatalf("list = %+v", got)
	}
	if len(got.Plugins) != 1 {
		t.Fatalf("got %d plugins", len(got.Plugins))
	}
	p := got.Plugins[0]
	if p.Id != "alpha" || p.Name != "Alpha" || p.Icon != "circle" || p.Path != "/p/alpha/" {
		t.Fatalf("plugin = %+v", p)
	}
	if p.State != clientv1.State_STARTING {
		t.Fatalf("state = %v, want STARTING", p.State)
	}
}

// ui: none means "no tab in the client" — the plugin still runs, it just
// never appears in the roster.
func TestHeadlessPluginsAreNotInTheRoster(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	reg.Add(Manifest{ID: "sensor", Name: "Sensor", Exec: "./s", UI: "none"})
	s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "" }, "")

	got := s.toPluginList(reg.Snapshot())
	if len(got.Plugins) != 1 || got.Plugins[0].Id != "alpha" {
		t.Fatalf("roster = %+v, want only the webview plugin", got.Plugins)
	}
}

func TestStateMapping(t *testing.T) {
	want := map[State]clientv1.State{
		StateStarting: clientv1.State_STARTING,
		StateUp:       clientv1.State_UP,
		StateDegraded: clientv1.State_DEGRADED,
		StateDown:     clientv1.State_DOWN,
		StateFailed:   clientv1.State_FAILED,
	}
	for in, out := range want {
		if got := toProtoState(in); got != out {
			t.Errorf("toProtoState(%v) = %v, want %v", in, got, out)
		}
	}
}

// The exit reason must survive into the roster, or a client showing an
// error page has nothing to say.
func TestDetailSurvivesIntoTheRoster(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	reg.SetState("alpha", StateFailed, "5 consecutive failed starts")
	s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "" }, "")

	got := s.toPluginList(reg.Snapshot())
	if got.Plugins[0].Detail != "5 consecutive failed starts" {
		t.Fatalf("detail = %q", got.Plugins[0].Detail)
	}
}
