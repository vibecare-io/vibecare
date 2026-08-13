package kernel

import (
	"testing"
	"time"

	"go.uber.org/zap"
)

func testRegistry(t *testing.T, ids ...string) *Registry {
	t.Helper()
	r := NewRegistry(zap.NewNop())
	for _, id := range ids {
		r.Add(Manifest{ID: id, Name: id, Icon: "circle", Exec: "./" + id, UI: "webview", Dir: "/tmp/" + id})
	}
	return r
}

func TestRegistryNewPluginStartsStarting(t *testing.T) {
	r := testRegistry(t, "alpha")
	got, ok := r.State("alpha")
	if !ok || got != StateStarting {
		t.Fatalf("state = %v, %v; want starting", got, ok)
	}
}

func TestStateStrings(t *testing.T) {
	want := map[State]string{
		StateStarting: "starting", StateUp: "up", StateDegraded: "degraded",
		StateDown: "down", StateFailed: "failed",
	}
	for s, w := range want {
		if s.String() != w {
			t.Errorf("State(%d).String() = %q, want %q", s, s.String(), w)
		}
	}
}

func TestSnapshotPathIsStable(t *testing.T) {
	r := testRegistry(t, "alpha")
	s := r.Snapshot()
	if len(s) != 1 || s[0].Path != "/p/alpha/" {
		t.Fatalf("snapshot = %+v, want path /p/alpha/", s)
	}
	// A restart changes port and pid but must never change the path — the
	// client keeps one webview URL for the life of the plugin.
	r.SetPort("alpha", 41000)
	r.SetProcess("alpha", 999)
	r.IncRestarts("alpha")
	if r.Snapshot()[0].Path != "/p/alpha/" {
		t.Fatal("path changed across restart")
	}
}

func TestSnapshotIsSortedByID(t *testing.T) {
	r := testRegistry(t, "zeta", "alpha", "mid")
	got := r.Snapshot()
	if got[0].ID != "alpha" || got[1].ID != "mid" || got[2].ID != "zeta" {
		t.Fatalf("unsorted: %+v", got)
	}
}

func TestWatchReceivesCurrentSnapshotImmediately(t *testing.T) {
	r := testRegistry(t, "alpha")
	ch, cancel := r.Watch()
	defer cancel()

	select {
	case snap := <-ch:
		if len(snap) != 1 || snap[0].State != StateStarting {
			t.Fatalf("first snapshot = %+v", snap)
		}
	case <-time.After(time.Second):
		t.Fatal("no initial snapshot delivered")
	}
}

func TestWatchNotifiesOnStateChange(t *testing.T) {
	r := testRegistry(t, "alpha")
	ch, cancel := r.Watch()
	defer cancel()
	<-ch // drain initial

	r.SetState("alpha", StateUp, "")

	select {
	case snap := <-ch:
		if snap[0].State != StateUp {
			t.Fatalf("state = %v, want up", snap[0].State)
		}
	case <-time.After(time.Second):
		t.Fatal("state change did not notify")
	}
}

// Setting the same state twice must stay quiet, otherwise every 10s health
// probe would re-push the entire roster to every connected client.
func TestWatchIgnoresRedundantSetState(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateUp, "")
	ch, cancel := r.Watch()
	defer cancel()
	<-ch // drain initial

	r.SetState("alpha", StateUp, "")

	select {
	case snap := <-ch:
		t.Fatalf("redundant SetState notified: %+v", snap)
	case <-time.After(100 * time.Millisecond):
	}
}

// A detail change (e.g. a new /health detail string) IS a change worth
// pushing — it's what the dashboard and the roster row display.
func TestWatchNotifiesOnDetailChange(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateDegraded, "camera busy")
	ch, cancel := r.Watch()
	defer cancel()
	<-ch

	r.SetState("alpha", StateDegraded, "camera unavailable")
	select {
	case snap := <-ch:
		if snap[0].Detail != "camera unavailable" {
			t.Fatalf("detail = %q", snap[0].Detail)
		}
	case <-time.After(time.Second):
		t.Fatal("detail change did not notify")
	}
}

// A slow watcher must never block a state transition; the pending snapshot
// is replaced with the newest one instead.
func TestWatchDoesNotBlockOnSlowConsumer(t *testing.T) {
	r := testRegistry(t, "alpha")
	ch, cancel := r.Watch()
	defer cancel()
	// Deliberately do NOT drain. Buffer is 1 and already holds the initial.

	done := make(chan struct{})
	go func() {
		r.SetState("alpha", StateUp, "")
		r.SetState("alpha", StateDown, "exit status 1")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("SetState blocked on a slow watcher")
	}

	// Whatever is buffered must be the newest state, not a stale one.
	snap := <-ch
	if snap[0].State != StateDown {
		t.Fatalf("buffered snapshot = %v, want the newest (down)", snap[0].State)
	}
}

func TestCancelWatchStopsDelivery(t *testing.T) {
	r := testRegistry(t, "alpha")
	ch, cancel := r.Watch()
	<-ch
	cancel()
	cancel() // must be idempotent

	r.SetState("alpha", StateUp, "")
	if _, open := <-ch; open {
		t.Fatal("channel should be closed after cancel")
	}
}

func TestStatCounters(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.CountPublished("alpha")
	r.CountPublished("alpha")
	r.CountDelivered("alpha", 3)
	r.SetProbeLatency("alpha", 12*time.Millisecond)
	r.IncRestarts("alpha")

	s := r.Snapshot()[0]
	if s.EventsPublished != 2 || s.EventsDelivered != 3 {
		t.Errorf("counters = %d published, %d delivered", s.EventsPublished, s.EventsDelivered)
	}
	if s.ProbeLatencyMS != 12 {
		t.Errorf("probe latency = %d ms", s.ProbeLatencyMS)
	}
	if s.Restarts != 1 {
		t.Errorf("restarts = %d", s.Restarts)
	}
	if s.LastEventUnix == 0 {
		t.Error("LastEventUnix should be stamped by CountPublished")
	}
}

// A down plugin has no uptime; reporting one would be a lie on the dashboard.
func TestUptimeOnlyWhileRunning(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateUp, "")
	time.Sleep(1100 * time.Millisecond)
	if got := r.Snapshot()[0].UptimeSec; got < 1 {
		t.Fatalf("uptime = %d, want >= 1 while up", got)
	}
	r.SetState("alpha", StateDown, "killed")
	if got := r.Snapshot()[0].UptimeSec; got != 0 {
		t.Fatalf("uptime = %d, want 0 while down", got)
	}
}

func TestCompareAndSetStateSucceedsWhenExpectMatches(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateUp, "")

	if !r.CompareAndSetState("alpha", StateUp, StateDegraded, "camera busy") {
		t.Fatal("CAS with matching expect should succeed")
	}
	got, _ := r.State("alpha")
	if got != StateDegraded {
		t.Fatalf("state = %v, want degraded", got)
	}
}

// A CAS whose expect no longer matches must change nothing — not the
// state, not the detail, and it must not wake a watcher, since nothing
// about the roster actually moved.
func TestCompareAndSetStateFailsWhenExpectStale(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateDown, "exit status 1")

	ch, cancel := r.Watch()
	defer cancel()
	<-ch // drain initial

	if r.CompareAndSetState("alpha", StateUp, StateDegraded, "should not apply") {
		t.Fatal("CAS with stale expect should fail")
	}
	got, detail := stateAndDetail(t, r, "alpha")
	if got != StateDown || detail != "exit status 1" {
		t.Fatalf("state = %v, detail = %q; a failed CAS must not mutate", got, detail)
	}

	select {
	case snap := <-ch:
		t.Fatalf("failed CAS notified watchers: %+v", snap)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestCompareAndSetStateUnknownIDFails(t *testing.T) {
	r := testRegistry(t)
	if r.CompareAndSetState("ghost", StateUp, StateDegraded, "") {
		t.Fatal("CAS on an unknown id should fail")
	}
}

// A successful CAS is a real transition and must notify exactly like
// SetState does.
func TestCompareAndSetStateNotifiesWatchersLikeSetState(t *testing.T) {
	r := testRegistry(t, "alpha")
	r.SetState("alpha", StateUp, "")

	ch, cancel := r.Watch()
	defer cancel()
	<-ch // drain initial

	if !r.CompareAndSetState("alpha", StateUp, StateDown, "exit status 1") {
		t.Fatal("CAS with matching expect should succeed")
	}

	select {
	case snap := <-ch:
		if snap[0].State != StateDown || snap[0].Detail != "exit status 1" {
			t.Fatalf("snapshot = %+v", snap[0])
		}
	case <-time.After(time.Second):
		t.Fatal("successful CAS did not notify")
	}
}

func stateAndDetail(t *testing.T, r *Registry, id string) (State, string) {
	t.Helper()
	for _, s := range r.Snapshot() {
		if s.ID == id {
			return s.State, s.Detail
		}
	}
	t.Fatalf("no such plugin %q", id)
	return StateStarting, ""
}

// Mutations against an unknown id are no-ops rather than panics: the health
// prober and supervisor can race with a plugin being removed.
func TestUnknownIDIsSafe(t *testing.T) {
	r := testRegistry(t)
	r.SetState("ghost", StateUp, "")
	r.SetPort("ghost", 1)
	r.CountPublished("ghost")
	if _, ok := r.State("ghost"); ok {
		t.Fatal("ghost should not exist")
	}
}
