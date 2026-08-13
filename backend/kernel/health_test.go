package kernel

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"

	"go.uber.org/zap"
)

// serverPort starts s and returns the loopback port it bound.
func serverPort(t *testing.T, s *httptest.Server) uint32 {
	t.Helper()
	u, err := url.Parse(s.URL)
	if err != nil {
		t.Fatal(err)
	}
	p, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	return uint32(p)
}

func TestAdvanceStateMachine(t *testing.T) {
	ok := probeResult{ok: true}
	bad := probeResult{ok: false}
	selfDegraded := probeResult{ok: true, reportedDegraded: true, detail: "camera busy"}

	cases := []struct {
		name      string
		cur       State
		r         probeResult
		fails     int
		wantState State
		wantFails int
	}{
		{"healthy stays up", StateUp, ok, 0, StateUp, 0},
		{"one bad probe does not move", StateUp, bad, 0, StateUp, 1},
		{"two bad probes do not move", StateUp, bad, 1, StateUp, 2},
		{"three bad probes degrade", StateUp, bad, 2, StateDegraded, 0},
		{"degraded plus three more goes down", StateDegraded, bad, 2, StateDown, 0},
		{"degraded plus one bad stays degraded", StateDegraded, bad, 0, StateDegraded, 1},
		{"probe recovery clears degraded", StateDegraded, ok, 2, StateUp, 0},
		{"recovery resets the counter", StateUp, ok, 2, StateUp, 0},
		{"self-reported degraded is immediate", StateUp, selfDegraded, 0, StateDegraded, 0},
		{"self-reported degraded from degraded stays", StateDegraded, selfDegraded, 1, StateDegraded, 0},
		{"down is not the prober's to change", StateDown, bad, 0, StateDown, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotState, gotFails := advance(c.cur, c.r, c.fails)
			if gotState != c.wantState || gotFails != c.wantFails {
				t.Fatalf("advance(%v, ok=%v deg=%v, %d) = (%v, %d); want (%v, %d)",
					c.cur, c.r.ok, c.r.reportedDegraded, c.fails,
					gotState, gotFails, c.wantState, c.wantFails)
			}
		})
	}
}

func TestProbeHealthPlainOK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Errorf("probed %q, want /health", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
	if !got.ok || got.reportedDegraded {
		t.Fatalf("result = %+v, want plain ok", got)
	}
	if got.latency <= 0 {
		t.Error("latency should be measured")
	}
}

// A plugin may enrich the probe with JSON; detail is free text the
// dashboard shows verbatim.
func TestProbeHealthParsesDetailJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"degraded","detail":"camera: FaceTime HD","since":"2026-08-13T09:12:00Z"}`))
	}))
	defer srv.Close()

	got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
	if !got.ok || !got.reportedDegraded || got.detail != "camera: FaceTime HD" {
		t.Fatalf("result = %+v", got)
	}
}

// Most plugins return an empty 200 from the SDK's default handler; that
// must not be misread as degraded.
func TestProbeHealthEmptyBodyIsOK(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	defer srv.Close()
	if got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv)); !got.ok || got.reportedDegraded {
		t.Fatalf("result = %+v, want ok", got)
	}
}

func TestProbeHealthNon200IsFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	if got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv)); got.ok {
		t.Fatalf("503 reported ok: %+v", got)
	}
}

func TestProbeHealthUnreachablePortIsFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	port := serverPort(t, srv)
	client := srv.Client()
	srv.Close() // nothing listening now

	if got := probeHealth(context.Background(), client, port); got.ok {
		t.Fatalf("closed port reported ok: %+v", got)
	}
}

// A hung handler is exactly the failure the stream signal cannot see: the
// process is alive, the data plane is not.
func TestProbeHealthTimesOut(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { <-block }))
	defer func() { close(block); srv.Close() }()

	probeTimeout = 100 * time.Millisecond
	t.Cleanup(func() { probeTimeout = 2 * time.Second })

	start := time.Now()
	got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
	if got.ok {
		t.Fatal("hung handler reported ok")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("probe took %v; the timeout is not being applied", elapsed)
	}
}

// End to end through the registry: three bad probes move an up plugin to
// degraded and record the probe latency for the dashboard.
func TestHealthDegradesAfterThreeBadProbes(t *testing.T) {
	fail := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		select {
		case <-fail:
			w.WriteHeader(http.StatusInternalServerError)
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()

	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "alpha", Exec: "./a", UI: "webview"})
	reg.SetPort("alpha", serverPort(t, srv))
	reg.SetState("alpha", StateUp, "")

	h := NewHealth(reg, zap.NewNop())
	ctx := context.Background()

	h.ProbeOnce(ctx)
	if got, _ := reg.State("alpha"); got != StateUp {
		t.Fatalf("healthy probe moved state to %v", got)
	}
	if reg.Snapshot()[0].ProbeLatencyMS < 0 {
		t.Error("probe latency not recorded")
	}

	close(fail)
	h.ProbeOnce(ctx)
	h.ProbeOnce(ctx)
	if got, _ := reg.State("alpha"); got != StateUp {
		t.Fatalf("state = %v after 2 bad probes, want still up (no flapping)", got)
	}
	h.ProbeOnce(ctx)
	if got, _ := reg.State("alpha"); got != StateDegraded {
		t.Fatalf("state = %v after 3 bad probes, want degraded", got)
	}
}

// Plugins that aren't running have nothing to probe; probing them would
// fight the supervisor over who owns the state.
func TestHealthSkipsPluginsWithoutPortOrNotRunning(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "noport", Name: "noport", Exec: "./a", UI: "webview"})
	reg.Add(Manifest{ID: "down", Name: "down", Exec: "./b", UI: "webview"})
	reg.SetPort("down", 1) // port 1: nothing listens there
	reg.SetState("down", StateDown, "exit status 1")

	h := NewHealth(reg, zap.NewNop())
	h.ProbeOnce(context.Background())

	if got, _ := reg.State("noport"); got != StateStarting {
		t.Errorf("unregistered plugin moved to %v", got)
	}
	if got, _ := reg.State("down"); got != StateDown {
		t.Errorf("down plugin moved to %v", got)
	}
}
