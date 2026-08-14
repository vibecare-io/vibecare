package kernel

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// hostFixture spins the real PluginHost service over an in-memory
// connection, so tests exercise the actual gRPC path rather than calling
// methods directly.
type hostFixture struct {
	reg     *Registry
	bus     *Bus
	intents *Intents
	host    *Host
	client  pluginv1.PluginHostClient
}

func newHostFixture(t *testing.T, manifests ...Manifest) *hostFixture {
	t.Helper()
	reg := NewRegistry(zap.NewNop())
	bus := NewBus(zap.NewNop())
	for _, m := range manifests {
		reg.Add(m)
		bus.Declare(m.ID, m.Subscribes, m.Publishes)
	}
	sup := NewSupervisor(reg, "/tmp/unused.sock", t.TempDir(), zap.NewNop())
	health := NewHealth(reg, zap.NewNop())
	intents := NewIntents(zap.NewNop())

	host := NewHost(reg, bus, sup, health, intents, zap.NewNop())

	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	pluginv1.RegisterPluginHostServer(srv, host)
	go srv.Serve(lis)
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })

	return &hostFixture{
		reg: reg, bus: bus, intents: intents, host: host,
		client: pluginv1.NewPluginHostClient(conn),
	}
}

// asPlugin returns a context carrying the caller-attribution metadata the
// SDK attaches to every outbound call.
func asPlugin(id string) context.Context {
	return metadata.AppendToOutgoingContext(context.Background(), pluginwire.PluginIDMetadataKey, id)
}

func TestRegisterReadiesPluginAndRecordsPort(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 41234})
	if err != nil {
		t.Fatal(err)
	}

	msg, err := stream.Recv()
	if err != nil {
		t.Fatalf("first message: %v", err)
	}
	if msg.GetReady() == nil {
		t.Fatalf("first message = %+v, want Ready", msg)
	}
	if got, _ := f.reg.Port("alpha"); got != 41234 {
		t.Errorf("port = %d, want 41234", got)
	}
	if got, _ := f.reg.State("alpha"); got != StateUp {
		t.Errorf("state = %v, want up", got)
	}
}

func TestRegisterRejectsUnknownPlugin(t *testing.T) {
	f := newHostFixture(t)
	stream, err := f.client.Register(context.Background(), &pluginv1.RegisterReq{Id: "ghost", HttpPort: 1})
	if err == nil {
		_, err = stream.Recv()
	}
	if err == nil {
		t.Fatal("expected an error registering an undiscovered plugin")
	}
}

// The stream's second job: delivering subscribed bus events.
func TestRegisterStreamDeliversSubscribedEvents(t *testing.T) {
	f := newHostFixture(t,
		Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"t.v1"}},
		Manifest{ID: "sink", Name: "K", Exec: "./k", UI: "none", Subscribes: []string{"t.v1"}},
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "sink", HttpPort: 1})
	if err != nil {
		t.Fatal(err)
	}
	if msg, err := stream.Recv(); err != nil || msg.GetReady() == nil {
		t.Fatalf("want Ready first: %+v %v", msg, err)
	}

	ts := time.Unix(1700000000, 0)
	if _, err := f.client.Publish(asPlugin("sensor"), &pluginv1.Event{
		Topic: "t.v1", Payload: []byte("hi"), Ts: timestamppb.New(ts),
	}); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	msg, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	ev := msg.GetEvent()
	if ev == nil || ev.Topic != "t.v1" || string(ev.Payload) != "hi" {
		t.Fatalf("event = %+v", msg)
	}
	if got := f.reg.Snapshot(); got[0].EventsPublished != 1 && got[1].EventsPublished != 1 {
		t.Error("publish was not counted against the publisher")
	}
}

func TestPublishWithoutAttributionIsRejected(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"t.v1"}})
	if _, err := f.client.Publish(context.Background(), &pluginv1.Event{Topic: "t.v1"}); err == nil {
		t.Fatal("expected an error for an unattributed Publish")
	}
}

func TestPublishUndeclaredTopicIsRejectedOverRPC(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"declared.v1"}})
	if _, err := f.client.Publish(asPlugin("sensor"), &pluginv1.Event{Topic: "sneaky.v1"}); err == nil {
		t.Fatal("expected an error publishing an undeclared topic")
	}
}

func TestAlertReachesIntentSubscribers(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	ch, cancel := f.intents.Subscribe()
	defer cancel()

	_, err := f.client.Alert(asPlugin("alpha"), &pluginv1.AlertReq{
		Title: "Break time", Body: "Stand up", Level: "info",
		Actions: []*pluginv1.AlertAction{{Label: "Snooze", Url: "snooze"}},
	})
	if err != nil {
		t.Fatal(err)
	}

	select {
	case a := <-ch:
		if a.Plugin != "alpha" || a.Title != "Break time" || a.Level != "info" {
			t.Fatalf("alert = %+v", a)
		}
		if len(a.Actions) != 1 || a.Actions[0].Label != "Snooze" || a.Actions[0].Url != "snooze" {
			t.Fatalf("actions = %+v", a.Actions)
		}
	case <-time.After(time.Second):
		t.Fatal("alert never reached the intents fan-out")
	}
}

// Alerts are transient: a client that connects after one fired does not
// see it.
func TestAlertsAreNotRetained(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	f.client.Alert(asPlugin("alpha"), &pluginv1.AlertReq{Title: "early"})
	time.Sleep(50 * time.Millisecond)

	ch, cancel := f.intents.Subscribe()
	defer cancel()
	select {
	case a := <-ch:
		t.Fatalf("late subscriber received a retained alert: %+v", a)
	case <-time.After(200 * time.Millisecond):
	}
}

// A dropped stream means the plugin is reconnecting, not dead — the
// supervisor owns down/failed.
func TestStreamLossMovesPluginToStarting(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	ctx, cancel := context.WithCancel(context.Background())
	stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 1})
	if err != nil {
		t.Fatal(err)
	}
	stream.Recv() // Ready
	cancel()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got, _ := f.reg.State("alpha"); got == StateStarting {
			if d := f.reg.Snapshot()[0].Detail; d != "reconnecting" {
				t.Fatalf("detail = %q, want reconnecting", d)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	got, _ := f.reg.State("alpha")
	t.Fatalf("state = %v after stream loss, want starting", got)
}

func TestBroadcastShutdownReachesPlugins(t *testing.T) {
	f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 1})
	if err != nil {
		t.Fatal(err)
	}
	stream.Recv() // Ready

	go f.host.BroadcastShutdown("core shutting down")

	msg, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	sd := msg.GetShutdown()
	if sd == nil || sd.Reason != "core shutting down" {
		t.Fatalf("message = %+v, want Shutdown", msg)
	}
}
