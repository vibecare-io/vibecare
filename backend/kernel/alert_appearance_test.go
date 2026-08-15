package kernel

import (
	"context"
	"net"
	"testing"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"
)

// hopFixture wires the real PluginHost and the real Shell service to ONE
// Intents fan-out over two in-memory connections, so a test can drive the
// whole plugin -> core -> client path end to end rather than asserting on
// an intermediate struct. That end-to-end shape is the point: the field
// under test here is one the kernel must forward without interpreting, and
// a test that stopped at Intents.Broadcast would not notice the Shell
// service dropping it on the way out.
type hopFixture struct {
	plugin pluginv1.PluginHostClient
	shell  clientv1.ShellClient
}

func newHopFixture(t *testing.T, manifests ...Manifest) *hopFixture {
	t.Helper()
	log := zap.NewNop()
	reg := NewRegistry(log)
	bus := NewBus(log)
	for _, m := range manifests {
		reg.Add(m)
		bus.Declare(m.ID, m.Subscribes, m.Publishes)
	}
	intents := NewIntents(log)
	host := NewHost(reg, bus,
		NewSupervisor(reg, "/tmp/unused.sock", t.TempDir(), t.TempDir(), log),
		NewHealth(reg, log), intents, log)
	shell := NewShellService(reg, intents, func(context.Context) string { return "http://127.0.0.1:1" }, "tok")

	dial := func(register func(*grpc.Server)) *grpc.ClientConn {
		lis := bufconn.Listen(1 << 20)
		srv := grpc.NewServer()
		register(srv)
		go srv.Serve(lis)
		t.Cleanup(srv.Stop)

		conn, err := grpc.NewClient("passthrough:///bufnet",
			grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
			grpc.WithTransportCredentials(insecure.NewCredentials()))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		return conn
	}

	return &hopFixture{
		plugin: pluginv1.NewPluginHostClient(dial(func(s *grpc.Server) { pluginv1.RegisterPluginHostServer(s, host) })),
		shell:  clientv1.NewShellClient(dial(func(s *grpc.Server) { clientv1.RegisterShellServer(s, shell) })),
	}
}

func (f *hopFixture) openIntents(t *testing.T) clientv1.Shell_IntentsClient {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	stream, err := f.shell.Intents(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	// The stream is established lazily; send a throwaway alert and wait for
	// it, so the subscription is provably registered before the alert the
	// test actually asserts on is broadcast. Intents retains nothing, so a
	// race here would look like a dropped field rather than a flake.
	if _, err := f.plugin.Alert(asAttributed("alpha"), &pluginv1.AlertReq{Title: "warmup"}); err != nil {
		t.Fatal(err)
	}
	for {
		msg, err := stream.Recv()
		if err != nil {
			t.Fatalf("warmup recv: %v", err)
		}
		if msg.GetAlert().GetTitle() == "warmup" {
			return stream
		}
	}
}

// asAttributed mirrors the caller-attribution metadata the SDK attaches to
// every outbound call. Deliberately a separate helper from rpc_test.go's
// asPlugin so this file does not depend on edits to that one.
func asAttributed(id string) context.Context {
	return metadata.AppendToOutgoingContext(context.Background(), pluginwire.PluginIDMetadataKey, id)
}

// The kernel must forward `appearance` byte for byte and never look inside
// it: it is an opaque blob whose schema belongs to the plugin that sent it
// and the client that renders it (D10 — the kernel has no product
// semantics, so it cannot have an opinion on what an alert looks like).
//
// The blob below is deliberately hostile to a naive relay: nested quotes,
// a backslash escape, a multi-byte character, and a newline. Any layer that
// re-serialized, trimmed, or round-tripped it through a JSON decode would
// change these bytes and fail here.
func TestAlertAppearanceSurvivesTheHopUnmodified(t *testing.T) {
	f := newHopFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	stream := f.openIntents(t)

	blob := `{"position":"center","title":"say \"hi\" 💛","width":450,"lines":"a\nb"}`

	_, err := f.plugin.Alert(asAttributed("alpha"), &pluginv1.AlertReq{
		Title: "T", Body: "B", Level: "warn",
		Appearance: &blob,
	})
	if err != nil {
		t.Fatal(err)
	}

	msg, err := stream.Recv()
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	alert := msg.GetAlert()
	if alert == nil {
		t.Fatalf("intent carried no alert: %+v", msg)
	}
	if alert.Appearance == nil {
		t.Fatal("alert lost the appearance field entirely")
	}
	if got := alert.GetAppearance(); got != blob {
		t.Fatalf("appearance was modified in transit:\n got %q\nwant %q", got, blob)
	}
}

// The field is optional in the wire sense, not merely empty-string-able: a
// plugin that sends no appearance must produce an alert a client can tell
// apart from one carrying a deliberately blank appearance. Without explicit
// presence the client cannot distinguish "style me" from "don't", and would
// have to guess.
func TestAlertWithoutAppearanceReportsNoPresence(t *testing.T) {
	f := newHopFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	stream := f.openIntents(t)

	if _, err := f.plugin.Alert(asAttributed("alpha"), &pluginv1.AlertReq{Title: "plain"}); err != nil {
		t.Fatal(err)
	}

	msg, err := stream.Recv()
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if msg.GetAlert().Appearance != nil {
		t.Fatalf("alert invented an appearance: %q", msg.GetAlert().GetAppearance())
	}
}

// An empty-but-present appearance stays present. This is the other half of
// the presence contract above, and it is the case a `if s != "" ` style
// relay silently breaks.
func TestEmptyAppearanceStaysPresent(t *testing.T) {
	f := newHopFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	stream := f.openIntents(t)

	blank := ""
	if _, err := f.plugin.Alert(asAttributed("alpha"), &pluginv1.AlertReq{Title: "blank", Appearance: &blank}); err != nil {
		t.Fatal(err)
	}

	msg, err := stream.Recv()
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	if msg.GetAlert().Appearance == nil {
		t.Fatal("an explicitly-empty appearance was dropped to absent")
	}
}
