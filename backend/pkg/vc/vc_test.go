package vc

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakeCore is a minimal PluginHost server: enough to exercise the SDK
// without dragging the kernel into the SDK's tests.
type fakeCore struct {
	pluginv1.UnimplementedPluginHostServer

	mu         sync.Mutex
	registered []*pluginv1.RegisterReq
	published  []*pluginv1.Event
	publishIDs []string
	alerts     []*pluginv1.AlertReq
	alertIDs   []string
	streams    []pluginv1.PluginHost_RegisterServer
	connects   int
}

func (f *fakeCore) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error {
	f.mu.Lock()
	f.registered = append(f.registered, req)
	f.streams = append(f.streams, stream)
	f.connects++
	f.mu.Unlock()

	if err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Ready{Ready: &pluginv1.Ready{}}}); err != nil {
		return err
	}
	<-stream.Context().Done()
	return stream.Context().Err()
}

func (f *fakeCore) Publish(ctx context.Context, e *pluginv1.Event) (*emptypb.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.published = append(f.published, e)
	f.publishIDs = append(f.publishIDs, idFrom(ctx))
	return &emptypb.Empty{}, nil
}

func (f *fakeCore) Alert(ctx context.Context, a *pluginv1.AlertReq) (*emptypb.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.alerts = append(f.alerts, a)
	f.alertIDs = append(f.alertIDs, idFrom(ctx))
	return &emptypb.Empty{}, nil
}

// send pushes a core-originated message down the newest open stream.
func (f *fakeCore) send(msg *pluginv1.CoreMsg) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.streams) == 0 {
		return
	}
	f.streams[len(f.streams)-1].Send(msg)
}

func idFrom(ctx context.Context) string {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return ""
	}
	v := md.Get(pluginwire.PluginIDMetadataKey)
	if len(v) == 0 {
		return ""
	}
	return v[0]
}

// coreFixture starts a fakeCore on a unix socket and sets the three spawn
// env vars, exactly as the supervisor would.
func coreFixture(t *testing.T, id string) (*fakeCore, *grpc.Server) {
	t.Helper()
	dir := t.TempDir()
	dataDir := filepath.Join(dir, "data", id)
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		t.Fatal(err)
	}

	// The unix socket path has to stay short: macOS (and GitHub's macOS
	// runners) caps sockaddr_un.sun_path at 104 bytes, and t.TempDir()'s
	// default location is a long, deeply-nested path
	// (/var/folders/.../T/<TestName>/NNN) under a $TMPDIR that is itself
	// already long — combined with a descriptive test function name, that
	// routinely blows past the limit and fails net.Listen("unix", ...)
	// with "invalid argument" on a completely healthy SDK. A short, fixed
	// prefix under /tmp sidesteps both the test name length and whatever
	// $TMPDIR happens to be set to.
	sockDir, err := os.MkdirTemp("/tmp", "vcsdk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sockDir) })
	sock := filepath.Join(sockDir, "core.sock")

	lis, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	core := &fakeCore{}
	srv := grpc.NewServer()
	pluginv1.RegisterPluginHostServer(srv, core)
	go srv.Serve(lis)
	t.Cleanup(srv.Stop)

	t.Setenv("VIBECARE_SOCKET", sock)
	t.Setenv("VIBECARE_PLUGIN_ID", id)
	t.Setenv("VIBECARE_DATA_DIR", dataDir)
	return core, srv
}

func TestConnectRequiresSpawnEnvironment(t *testing.T) {
	t.Setenv("VIBECARE_SOCKET", "")
	t.Setenv("VIBECARE_PLUGIN_ID", "")
	t.Setenv("VIBECARE_DATA_DIR", "")
	if _, err := Connect(); err == nil {
		t.Fatal("expected an error when the spawn env is missing")
	}
}

func TestConnectRegistersWithTheListenerPort(t *testing.T) {
	core, _ := coreFixture(t, "alpha")

	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	if h.ID != "alpha" {
		t.Errorf("ID = %q", h.ID)
	}
	if h.DataDir == "" {
		t.Error("DataDir must come from VIBECARE_DATA_DIR")
	}
	if h.Listener == nil {
		t.Fatal("Connect must bind the plugin's HTTP listener")
	}

	_, portStr, _ := net.SplitHostPort(h.Listener.Addr().String())
	core.mu.Lock()
	defer core.mu.Unlock()
	if len(core.registered) != 1 {
		t.Fatalf("registered %d times, want 1", len(core.registered))
	}
	got := core.registered[0]
	if got.Id != "alpha" {
		t.Errorf("registered id = %q", got.Id)
	}
	if portStr != itoa(int(got.HttpPort)) {
		t.Errorf("registered port %d != listener port %s", got.HttpPort, portStr)
	}
}

// Most plugin authors write no health code at all; the SDK's default
// handler is what core probes.
func TestDefaultHealthHandler(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	mux := http.NewServeMux()
	go h.Serve(mux)

	resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d, want 200", resp.StatusCode)
	}
}

// A plugin that knows it is degraded says so, and core moves it there
// immediately rather than waiting for probes to fail.
func TestSetHealthReportsDegraded(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	h.SetHealth(func() (string, string) { return "degraded", "camera busy" })

	mux := http.NewServeMux()
	go h.Serve(mux)

	resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var body struct {
		Status string `json:"status"`
		Detail string `json:"detail"`
	}
	if err := jsonDecode(resp.Body, &body); err != nil {
		t.Fatal(err)
	}
	if body.Status != "degraded" || body.Detail != "camera busy" {
		t.Fatalf("body = %+v", body)
	}
}

// TestServeNilGoesThroughTheAdvertisedPath exercises the package doc
// comment's worked example verbatim: a plugin that calls
// http.Serve(h.Listener, nil) directly — writing zero health code — still
// gets a working /health, because Connect already installed the default
// handler on http.DefaultServeMux. This is the SDK's headline "no health
// code at all" claim and must be tested end to end, not only through an
// explicit mux as the other health tests do. It must also keep passing
// when the whole package runs, not just in isolation, since every test
// that calls Connect shares this same process-wide http.DefaultServeMux.
func TestServeNilGoesThroughTheAdvertisedPath(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	go http.Serve(h.Listener, nil)

	resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d, want 200", resp.StatusCode)
	}
}

// h.Serve(nil) is documented to take the same path as
// http.Serve(h.Listener, nil); cover it too.
func TestHandleServeNilGoesThroughTheAdvertisedPath(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	go h.Serve(nil)

	resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d, want 200", resp.StatusCode)
	}
}

// A caller who passes http.DefaultServeMux to Serve should not panic:
// Connect already registered /health there via the sync.Once indirection,
// and *http.ServeMux.HandleFunc panics on a duplicate pattern. Serve must
// detect that case and repoint the indirection instead of re-registering.
func TestServeToleratesExplicitDefaultServeMux(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	go h.Serve(http.DefaultServeMux)

	resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d, want 200", resp.StatusCode)
	}
}

func TestPublishAttachesPluginID(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	if err := h.Publish("alpha.thing.v1", []byte("payload")); err != nil {
		t.Fatal(err)
	}

	core.mu.Lock()
	defer core.mu.Unlock()
	if len(core.published) != 1 {
		t.Fatalf("published %d events", len(core.published))
	}
	if core.published[0].Topic != "alpha.thing.v1" || string(core.published[0].Payload) != "payload" {
		t.Fatalf("event = %+v", core.published[0])
	}
	if core.publishIDs[0] != "alpha" {
		t.Fatalf("caller attribution = %q, want alpha", core.publishIDs[0])
	}
	if !core.published[0].GetTs().IsValid() {
		t.Error("the SDK must stamp ts so plugins don't have to")
	}
}

func TestAlertAttachesPluginIDAndActions(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	err = h.Alert(Alert{
		Title: "Break", Body: "Stand", Level: "info",
		Actions: []AlertAction{{Label: "Snooze", URL: "snooze"}},
	})
	if err != nil {
		t.Fatal(err)
	}

	core.mu.Lock()
	defer core.mu.Unlock()
	if len(core.alerts) != 1 || core.alertIDs[0] != "alpha" {
		t.Fatalf("alerts = %+v ids = %v", core.alerts, core.alertIDs)
	}
	a := core.alerts[0]
	if a.Title != "Break" || len(a.Actions) != 1 || a.Actions[0].Url != "snooze" {
		t.Fatalf("alert = %+v", a)
	}
}

func TestEventsArriveOnTheChannel(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	core.send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Event{Event: &pluginv1.Event{
		Topic: "t.v1", Payload: []byte("hi"),
	}}})

	select {
	case e := <-h.Events:
		if e.Topic != "t.v1" || string(e.Payload) != "hi" {
			t.Fatalf("event = %+v", e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("event never reached the plugin")
	}
}

func TestShutdownCallbackFires(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	fired := make(chan struct{})
	h.OnShutdown(func() { close(fired) })

	core.send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Shutdown{
		Shutdown: &pluginv1.Shutdown{Reason: "core shutting down"},
	}})

	select {
	case <-fired:
	case <-time.After(2 * time.Second):
		t.Fatal("OnShutdown never fired")
	}
}

// The reconnect loop is what makes a core restart survivable: without it,
// restarting core would kill every running plugin.
func TestReconnectsAfterStreamDrop(t *testing.T) {
	core, srv := coreFixture(t, "alpha")
	reconnectBase = 20 * time.Millisecond
	t.Cleanup(func() { reconnectBase = time.Second })

	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	core.mu.Lock()
	first := core.connects
	core.mu.Unlock()

	// Drop every stream, as a core restart would.
	srv.Stop()

	// Bring core back on the same socket path.
	sock := os.Getenv("VIBECARE_SOCKET")
	os.Remove(sock)
	lis, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv2 := grpc.NewServer()
	pluginv1.RegisterPluginHostServer(srv2, core)
	go srv2.Serve(lis)
	defer srv2.Stop()

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		core.mu.Lock()
		n := core.connects
		core.mu.Unlock()
		if n > first {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("plugin never re-registered after the stream dropped")
}

func itoa(n int) string { return strconv.Itoa(n) }

func jsonDecode(r io.Reader, v any) error { return json.NewDecoder(r).Decode(v) }
