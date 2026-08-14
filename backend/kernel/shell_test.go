package kernel

import (
	"context"
	"net"
	"testing"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"
)

// newShellFixture spins the real ShellService over an in-memory connection,
// so the RPC tests below exercise the actual gRPC path rather than calling
// the methods directly, the same reasoning newHostFixture in rpc_test.go
// applies to PluginHost.
func newShellFixture(t *testing.T, manifests ...Manifest) (*Registry, *Intents, clientv1.ShellClient) {
	t.Helper()
	reg := NewRegistry(zap.NewNop())
	for _, m := range manifests {
		reg.Add(m)
	}
	intents := NewIntents(zap.NewNop())
	svc := NewShellService(reg, intents, func() string { return "http://127.0.0.1:1" }, "tok123")

	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	clientv1.RegisterShellServer(srv, svc)
	go srv.Serve(lis)
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })

	return reg, intents, clientv1.NewShellClient(conn)
}

// The roster stream's whole point: the current list arrives immediately on
// connect, and a fresh full list arrives again on every state change — no
// deltas, no polling required of the client.
func TestPluginsStreamsSnapshotThenUpdatesOnStateChange(t *testing.T) {
	reg, _, client := newShellFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := client.Plugins(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatal(err)
	}

	first, err := stream.Recv()
	if err != nil {
		t.Fatalf("initial snapshot: %v", err)
	}
	if len(first.Plugins) != 1 || first.Plugins[0].Id != "alpha" || first.Plugins[0].State != clientv1.State_STARTING {
		t.Fatalf("initial list = %+v", first)
	}

	reg.SetState("alpha", StateUp, "")

	second, err := stream.Recv()
	if err != nil {
		t.Fatalf("update after state change: %v", err)
	}
	if len(second.Plugins) != 1 || second.Plugins[0].State != clientv1.State_UP {
		t.Fatalf("updated list = %+v, want state UP", second)
	}
}

// Alerts have no HTML equivalent: they must render with no window open and
// the plugin's webview never loaded, so they travel over their own stream,
// wrapped in a UIIntent.
func TestIntentsStreamsAlertWrappedInUIIntent(t *testing.T) {
	_, intents, client := newShellFixture(t)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := client.Intents(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatal(err)
	}

	// The server's Subscribe() happens inside the stream handler
	// goroutine, asynchronously with respect to this call returning, so a
	// single Broadcast right after Intents() could fire before anyone is
	// listening. Retry it until stream.Recv() below observes one, rather
	// than racing a fixed sleep against the server goroutine's startup.
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			intents.Broadcast(&clientv1.Alert{Plugin: "alpha", Title: "hi", Level: "info"})
			select {
			case <-done:
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()

	msg, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	a := msg.GetAlert()
	if a == nil || a.Plugin != "alpha" || a.Title != "hi" || a.Level != "info" {
		t.Fatalf("intent = %+v, want an Alert{alpha, hi, info}", msg)
	}
}

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
