package vc

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
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
	if a.Appearance != nil {
		t.Fatalf("an alert with no Appearance must not send one: %q", a.GetAppearance())
	}
}

// Appearance is opaque and optional: the SDK forwards exactly what the
// plugin set, without inspecting it and without inventing one.
func TestAlertCarriesAppearanceWhenSet(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	blob := `{"width":450,"quote":"say \"hi\""}`
	if err := h.Alert(Alert{Title: "Break", Appearance: &blob}); err != nil {
		t.Fatal(err)
	}

	core.mu.Lock()
	defer core.mu.Unlock()
	if len(core.alerts) != 1 {
		t.Fatalf("alerts = %+v", core.alerts)
	}
	if got := core.alerts[0]; got.Appearance == nil || got.GetAppearance() != blob {
		t.Fatalf("appearance = %v, want %q", got.Appearance, blob)
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

// A direct SIGTERM beats a gRPC round trip over a unix socket essentially
// always, so core's Shutdown message frequently loses that race even
// though core sends it first (Finding 1). The SDK's own SIGTERM trap is
// what makes OnShutdown fire anyway.
func TestSIGTERMRunsOnShutdown(t *testing.T) {
	coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	var calls int32
	fired := make(chan struct{}, 1)
	h.OnShutdown(func() {
		atomic.AddInt32(&calls, 1)
		select {
		case fired <- struct{}{}:
		default:
		}
	})

	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}

	select {
	case <-fired:
	case <-time.After(2 * time.Second):
		t.Fatal("OnShutdown never fired on SIGTERM")
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("OnShutdown ran %d times after SIGTERM, want 1", got)
	}
}

// In production a plugin can receive the Shutdown stream message AND
// SIGTERM for the same shutdown — that is the whole race Finding 1 is
// about. Both paths call runShutdown, and it must be idempotent: whichever
// arrives second must be a no-op, not a second invocation of the plugin
// author's flush logic.
func TestSIGTERMAndShutdownMessageAreIdempotentTogether(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	var calls int32
	h.OnShutdown(func() { atomic.AddInt32(&calls, 1) })

	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	core.send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Shutdown{
		Shutdown: &pluginv1.Shutdown{Reason: "core shutting down"},
	}})

	// Give both paths a moment to land, in whichever order.
	time.Sleep(200 * time.Millisecond)
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("OnShutdown ran %d times across SIGTERM + Shutdown message, want exactly 1", got)
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

// Finding 3: the reconnect ladder must reset to reconnectBase after a
// session that stayed connected for a meaningful stretch — mirroring
// Supervisor.stableUptime — rather than doubling forever regardless of how
// long the previous session lasted. Without the reset, a plugin that has
// reconnected a handful of times over its life waits reconnectMax on every
// later, wholly unrelated drop.
//
// This drives three drops and measures the wall-clock gap between each
// drop and the resulting reconnect: the first two happen in rapid
// succession (well under reconnectStable), which should inflate the ladder
// (d2 > d1); the plugin is then held connected past reconnectStable before
// a third drop, which must reconnect quickly again (d3 < d2) rather than at
// the further-inflated delay an un-reset ladder would use. Comparing
// relative gaps rather than absolute thresholds keeps this robust against
// scheduling noise.
func TestReconnectBackoffResetsAfterAStableSession(t *testing.T) {
	core, srv := coreFixture(t, "alpha")
	reconnectBase = 40 * time.Millisecond
	reconnectMax = 5 * time.Second
	reconnectStable = 250 * time.Millisecond
	t.Cleanup(func() {
		reconnectBase = time.Second
		reconnectMax = 30 * time.Second
		reconnectStable = 60 * time.Second
	})

	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	sock := os.Getenv("VIBECARE_SOCKET")
	cur := srv
	t.Cleanup(func() { cur.Stop() })

	// dropAndTime stops the current server, waits for the plugin to
	// re-register on a fresh one bound to the same socket path, and
	// returns how long the reconnect took.
	dropAndTime := func() time.Duration {
		core.mu.Lock()
		before := core.connects
		core.mu.Unlock()

		start := time.Now()
		cur.Stop()
		if err := os.Remove(sock); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		lis, err := net.Listen("unix", sock)
		if err != nil {
			t.Fatal(err)
		}
		cur = grpc.NewServer()
		pluginv1.RegisterPluginHostServer(cur, core)
		go cur.Serve(lis)

		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			core.mu.Lock()
			n := core.connects
			core.mu.Unlock()
			if n > before {
				return time.Since(start)
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("plugin never reconnected")
		return 0
	}

	// Two rapid-fire drops: neither session lives anywhere near
	// reconnectStable, so the ladder should climb (d2 noticeably bigger
	// than d1).
	d1 := dropAndTime()
	d2 := dropAndTime()

	// Now let the session stay up past reconnectStable before dropping
	// again.
	time.Sleep(reconnectStable + 100*time.Millisecond)
	d3 := dropAndTime()

	t.Logf("d1=%s d2=%s d3=%s", d1, d2, d3)
	if d2 <= d1 {
		t.Fatalf("d2 (%s) did not grow past d1 (%s); the ladder must climb on rapid drops for this test to mean anything", d2, d1)
	}
	if d3 >= d2 {
		t.Fatalf("d3 (%s) >= d2 (%s): the backoff ladder did not reset after a stable session (reconnectStable=%s)", d3, d2, reconnectStable)
	}
}

// --- Appearance -----------------------------------------------------------
//
// These tests pin the WIRE SCHEMA, not the Go API: the macOS client decodes
// this JSON with its own hand-written keys (PluginAlertAppearance.swift), so
// a renamed field or a changed enum spelling is a silent styling regression
// no compiler on either side would catch. Everything here is asserted
// against exact JSON text for that reason.

// An absent key means "keep the client default"; a key present with a zero
// value means that zero value. So a field nobody set must not appear at all.
func TestAppearanceOmitsUnsetFields(t *testing.T) {
	tests := []struct {
		name  string
		style *Appearance
		want  string
	}{
		{"nothing set at all", NewAppearance(), `{}`},
		{"one field set leaves the rest out", NewAppearance().WithSize(520, 260), `{"width":520,"height":260}`},
		{"icon only", NewAppearance().WithBundledIcon("yoga"), `{"bundledIconId":"yoga"}`},
		{
			"blur helper sets the flag as well as the intensity",
			NewAppearance().WithScreenBlur(BlurHeavy),
			`{"screenBlurEnabled":true,"screenBlurIntensity":"heavy"}`,
		},
		{
			"turning blur off drops the intensity that would be ignored anyway",
			NewAppearance().WithScreenBlur(BlurHeavy).WithoutScreenBlur(),
			`{"screenBlurEnabled":false}`,
		},
		// The zero-value cases: these must NOT be omitted, or "no border"
		// and "default border" become the same request.
		{"a zero size is a real request, not an omission", NewAppearance().WithSize(0, 0), `{"width":0,"height":0}`},
		{"false is a real request", NewAppearance().WithMoveable(false), `{"moveable":false}`},
		{"zero seconds is a real request", NewAppearance().WithAutoDismissAfter(0), `{"autoDismissAfter":0}`},
		{"the empty string is a real request", NewAppearance().WithSVGPath(""), `{"svgPath":""}`},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.style.JSON()
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("JSON() = %s, want %s", got, tc.want)
			}
		})
	}
}

// Every field, set individually, must land on the key name the Swift client
// actually reads.
func TestAppearanceSerialisesToTheDocumentedKeyNames(t *testing.T) {
	tests := []struct {
		field string
		style *Appearance
		want  string
	}{
		{"bundledIconId", &Appearance{BundledIconID: Ptr("water-bottle")}, `{"bundledIconId":"water-bottle"}`},
		{"svgPath", &Appearance{SVGPath: Ptr("assets/stretch.svg")}, `{"svgPath":"assets/stretch.svg"}`},
		{"svgWidth", &Appearance{SVGWidth: Ptr(240.0)}, `{"svgWidth":240}`},
		{"svgHeight", &Appearance{SVGHeight: Ptr(160.5)}, `{"svgHeight":160.5}`},
		{"position", &Appearance{Position: Ptr(PositionTopRight)}, `{"position":"topRight"}`},
		{"width", &Appearance{Width: Ptr(520.0)}, `{"width":520}`},
		{"height", &Appearance{Height: Ptr(260.0)}, `{"height":260}`},
		{"moveable", &Appearance{Moveable: Ptr(true)}, `{"moveable":true}`},
		{"autoDismissAfter", &Appearance{AutoDismissAfter: Ptr(30.0)}, `{"autoDismissAfter":30}`},
		{"screenBlurEnabled", &Appearance{ScreenBlurEnabled: Ptr(true)}, `{"screenBlurEnabled":true}`},
		{"screenBlurIntensity", &Appearance{ScreenBlurIntensity: Ptr(BlurLight)}, `{"screenBlurIntensity":"light"}`},
		{"title", &Appearance{Title: Ptr("ignored by the client")}, `{"title":"ignored by the client"}`},
		{"message", &Appearance{Message: Ptr("also ignored")}, `{"message":"also ignored"}`},
	}

	for _, tc := range tests {
		t.Run(tc.field, func(t *testing.T) {
			got, err := tc.style.JSON()
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("JSON() = %s, want %s", got, tc.want)
			}
		})
	}

	// And all of them together, in the declared order, so the full blob a
	// plugin sends is pinned too.
	full := NewAppearance().
		WithBundledIcon("yoga").
		WithSVG("assets/stretch.svg", 240, 160).
		WithPosition(PositionCenter).
		WithSize(520, 260).
		WithMoveable(false).
		WithAutoDismissAfter(30 * time.Second).
		WithScreenBlur(BlurHeavy)
	want := `{"bundledIconId":"yoga","svgPath":"assets/stretch.svg","svgWidth":240,"svgHeight":160,` +
		`"position":"center","width":520,"height":260,"moveable":false,"autoDismissAfter":30,` +
		`"screenBlurEnabled":true,"screenBlurIntensity":"heavy"}`
	got, err := full.JSON()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("full appearance =\n%s\nwant\n%s", got, want)
	}
}

// The enums are the two places where a wrong string is accepted by the JSON
// encoder and then quietly discarded by the client, so their spellings are
// pinned literally.
func TestAppearanceEnumConstantsMatchTheWireStrings(t *testing.T) {
	positions := []struct {
		got  Position
		want string
	}{
		{PositionCenter, "center"},
		{PositionTopLeft, "topLeft"},
		{PositionTopRight, "topRight"},
		{PositionBottomLeft, "bottomLeft"},
		{PositionBottomRight, "bottomRight"},
	}
	for _, tc := range positions {
		if string(tc.got) != tc.want {
			t.Errorf("Position = %q, want %q", tc.got, tc.want)
		}
	}

	blurs := []struct {
		got  BlurIntensity
		want string
	}{
		{BlurLight, "light"},
		{BlurMedium, "medium"},
		{BlurHeavy, "heavy"},
	}
	for _, tc := range blurs {
		if string(tc.got) != tc.want {
			t.Errorf("BlurIntensity = %q, want %q", tc.got, tc.want)
		}
	}
}

func TestAppearanceValidateRejectsValuesTheClientWouldDrop(t *testing.T) {
	tests := []struct {
		name    string
		style   *Appearance
		wantErr bool
	}{
		{"nil is fine", nil, false},
		{"empty is fine", NewAppearance(), false},
		{"every legal enum", NewAppearance().WithPosition(PositionBottomLeft).WithScreenBlur(BlurMedium), false},
		{"unknown position", &Appearance{Position: Ptr(Position("middle"))}, true},
		{"case matters", &Appearance{Position: Ptr(Position("TopRight"))}, true},
		{"unknown blur", &Appearance{ScreenBlurIntensity: Ptr(BlurIntensity("extreme"))}, true},
		{"negative width", &Appearance{Width: Ptr(-1.0)}, true},
		{"negative dismiss", &Appearance{AutoDismissAfter: Ptr(-5.0)}, true},
		{"zero is not negative", &Appearance{Width: Ptr(0.0)}, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.style.Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate() = %v, wantErr = %v", err, tc.wantErr)
			}
		})
	}
}

func TestAppearanceIsEmptyAndNilSafety(t *testing.T) {
	var nilStyle *Appearance
	if !nilStyle.IsEmpty() || !NewAppearance().IsEmpty() {
		t.Fatal("a nil or field-less Appearance must report itself empty")
	}
	if NewAppearance().WithMoveable(false).IsEmpty() {
		t.Fatal("moveable:false is a set field, not an empty appearance")
	}

	// Chaining off a nil pointer must not panic: a plugin that threads an
	// appearance through optional configuration has a path where nothing
	// set it yet.
	got, err := nilStyle.WithPosition(PositionTopLeft).JSON()
	if err != nil {
		t.Fatal(err)
	}
	if got != `{"position":"topLeft"}` {
		t.Fatalf("JSON() = %s", got)
	}
}

// The whole point of the typed path: it produces the same blob the raw
// string always did, and it wins when both are set.
func TestAlertStyleWinsOverRawAppearance(t *testing.T) {
	raw := `{"width":111}`
	typed := NewAppearance().WithSize(520, 260).WithPosition(PositionTopRight)

	tests := []struct {
		name  string
		alert Alert
		want  *string // nil = the SDK must not send an appearance at all
	}{
		{"neither set", Alert{Title: "a"}, nil},
		{"raw only, forwarded verbatim", Alert{Title: "b", Appearance: &raw}, &raw},
		{
			"typed only",
			Alert{Title: "c", Style: typed},
			Ptr(`{"position":"topRight","width":520,"height":260}`),
		},
		{
			"both set: typed wins and the raw blob is not sent, merged or appended",
			Alert{Title: "d", Appearance: &raw, Style: typed},
			Ptr(`{"position":"topRight","width":520,"height":260}`),
		},
		{
			"an empty typed style still wins, and is the {} the client rejects",
			Alert{Title: "e", Appearance: &raw, Style: NewAppearance()},
			Ptr(`{}`),
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			core, _ := coreFixture(t, "alpha")
			h, err := Connect()
			if err != nil {
				t.Fatal(err)
			}
			defer h.Close()

			if err := h.Alert(tc.alert); err != nil {
				t.Fatal(err)
			}

			core.mu.Lock()
			defer core.mu.Unlock()
			if len(core.alerts) != 1 {
				t.Fatalf("alerts = %+v", core.alerts)
			}
			got := core.alerts[0].Appearance
			switch {
			case tc.want == nil && got != nil:
				t.Fatalf("sent an appearance nobody asked for: %q", *got)
			case tc.want != nil && got == nil:
				t.Fatalf("sent no appearance, want %q", *tc.want)
			case tc.want != nil && *got != *tc.want:
				t.Fatalf("appearance = %s, want %s", *got, *tc.want)
			}
		})
	}
}

// A Style the client would silently mangle fails at the call site instead,
// and no alert goes out — a notification that renders wrong is worse than
// an error the plugin author can see.
func TestAlertRejectsAnInvalidStyleWithoutSending(t *testing.T) {
	core, _ := coreFixture(t, "alpha")
	h, err := Connect()
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()

	err = h.Alert(Alert{Title: "Break", Style: &Appearance{Position: Ptr(Position("middle"))}})
	if err == nil {
		t.Fatal("an out-of-set Position must be an error, not a silently dropped field")
	}
	if !strings.Contains(err.Error(), "middle") {
		t.Errorf("the error must name the offending value, got: %v", err)
	}

	core.mu.Lock()
	defer core.mu.Unlock()
	if len(core.alerts) != 0 {
		t.Fatalf("an invalid style must not send an alert: %+v", core.alerts)
	}
}

// ExampleAppearance is the runnable form of the doc comment's example: it
// proves the advertised chain compiles and prints the blob it produces.
func ExampleAppearance() {
	style := NewAppearance().
		WithBundledIcon("yoga").
		WithPosition(PositionCenter).
		WithSize(520, 260).
		WithSVGSize(240, 160).
		WithScreenBlur(BlurHeavy).
		WithAutoDismissAfter(30 * time.Second).
		WithMoveable(false)

	blob, err := style.JSON()
	if err != nil {
		panic(err)
	}
	fmt.Println(blob)

	// This is what you would hand to Handle.Alert:
	//
	//	h.Alert(vc.Alert{Title: "Stretch break", Body: "Stand up.", Style: style})

	// Output:
	// {"bundledIconId":"yoga","svgWidth":240,"svgHeight":160,"position":"center","width":520,"height":260,"moveable":false,"autoDismissAfter":30,"screenBlurEnabled":true,"screenBlurIntensity":"heavy"}
}

func itoa(n int) string { return strconv.Itoa(n) }

func jsonDecode(r io.Reader, v any) error { return json.NewDecoder(r).Decode(v) }
