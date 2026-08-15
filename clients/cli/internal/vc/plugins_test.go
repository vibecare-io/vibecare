package vc

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
)

func TestRosterEnrichedWithKernelStats(t *testing.T) {
	sess, f := newTestServer(t)

	r, err := sess.Roster(testCtx(t))
	if err != nil {
		t.Fatalf("Roster: %v", err)
	}
	if r.BaseURL != f.kernel.URL {
		t.Errorf("BaseURL = %q, want %q", r.BaseURL, f.kernel.URL)
	}
	if len(r.Plugins) != 1 {
		t.Fatalf("got %d plugins, want 1", len(r.Plugins))
	}
	p := r.Plugins[0]
	if !p.Stats {
		t.Fatal("Stats = false, want true when the kernel answered")
	}
	if p.ID != "todo" || p.Name != "Todo" {
		t.Errorf("identity = %q/%q, want todo/Todo", p.ID, p.Name)
	}
	if p.Icon != "checkmark" {
		t.Errorf("Icon = %q; the icon exists only on the stream and must survive the merge", p.Icon)
	}
	if p.State != StateUp {
		t.Errorf("State = %q, want %q", p.State, StateUp)
	}
	if p.PID != 4242 || p.UptimeSec != 90 || p.Restarts != 1 {
		t.Errorf("stats = pid %d uptime %d restarts %d, want 4242/90/1", p.PID, p.UptimeSec, p.Restarts)
	}
	if p.EventsPublished != 7 || p.EventsDelivered != 5 {
		t.Errorf("events = %d/%d, want 7/5", p.EventsPublished, p.EventsDelivered)
	}
	if p.LogPath == "" {
		t.Error("LogPath empty, want the kernel's value")
	}
}

// The kernel's HTTP surface being down is degraded, not fatal: the roster
// from the stream alone is still the most useful thing the client has.
func TestRosterWithoutKernelHTTPIsDegradedNotAnError(t *testing.T) {
	sess, _ := newTestServer(t, withoutKernel())

	r, err := sess.Roster(testCtx(t))
	if err != nil {
		t.Fatalf("Roster: %v", err)
	}
	if len(r.Plugins) != 1 {
		t.Fatalf("got %d plugins, want 1", len(r.Plugins))
	}
	p := r.Plugins[0]
	if p.Stats {
		t.Error("Stats = true, want false when the kernel HTTP surface is down")
	}
	if p.PID != 0 || p.Restarts != 0 {
		t.Errorf("stats populated without the kernel: pid %d restarts %d", p.PID, p.Restarts)
	}
	if p.ID != "todo" || p.State != StateUp {
		t.Errorf("stream fields lost: %q/%q", p.ID, p.State)
	}
}

// A plugin the kernel does not report is not an error either — it just keeps
// Stats=false while its neighbours are enriched.
func TestRosterMarksOnlyRowsTheKernelReported(t *testing.T) {
	sess, _ := newTestServer(t,
		withRoster(
			&clientv1.PluginInfo{Id: "todo", Name: "Todo", State: clientv1.State_UP},
			&clientv1.PluginInfo{Id: "ghost", Name: "Ghost", State: clientv1.State_STARTING},
		),
	)

	r, err := sess.Roster(testCtx(t))
	if err != nil {
		t.Fatalf("Roster: %v", err)
	}
	if len(r.Plugins) != 2 {
		t.Fatalf("got %d plugins, want 2", len(r.Plugins))
	}
	if !r.Plugins[0].Stats {
		t.Error("todo.Stats = false, want true")
	}
	if r.Plugins[1].Stats {
		t.Error("ghost.Stats = true, want false")
	}
	if r.Plugins[1].State != StateStarting {
		t.Errorf("ghost.State = %q, want %q", r.Plugins[1].State, StateStarting)
	}
}

func TestRosterTally(t *testing.T) {
	r := Roster{Plugins: []Plugin{
		{State: StateUp}, {State: StateUp}, {State: StateDegraded},
		{State: StateDown}, {State: StateFailed}, {State: StateStarting},
		{State: StateUnknown},
	}}
	got := r.Tally()
	want := Tally{Total: 7, Up: 2, Degraded: 1, Down: 1, Failed: 1, Starting: 1}
	if got != want {
		t.Errorf("Tally = %+v, want %+v", got, want)
	}
}

func TestWatchRosterPushesOnChange(t *testing.T) {
	sess, f := newTestServer(t)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch, err := sess.WatchRoster(ctx)
	if err != nil {
		t.Fatalf("WatchRoster: %v", err)
	}

	// The first roster may already be cached, so read until the pushed one
	// arrives rather than assuming which one is first.
	f.shell.push(&clientv1.PluginList{
		BaseUrl: f.kernel.URL,
		Token:   testToken,
		Plugins: []*clientv1.PluginInfo{
			{Id: "todo", Name: "Todo", State: clientv1.State_DEGRADED, Detail: "probe timeout"},
		},
	})

	deadline := time.After(5 * time.Second)
	for {
		select {
		case r, ok := <-ch:
			if !ok {
				t.Fatal("watcher closed before the pushed roster arrived")
			}
			if len(r.Plugins) == 1 && r.Plugins[0].State == StateDegraded {
				if r.Plugins[0].Detail != "probe timeout" {
					t.Errorf("Detail = %q, want %q", r.Plugins[0].Detail, "probe timeout")
				}
				return
			}
		case <-deadline:
			t.Fatal("no degraded roster within 5s")
		}
	}
}

func TestWatchRosterStopsWithContext(t *testing.T) {
	sess, _ := newTestServer(t)

	ctx, cancel := context.WithCancel(context.Background())
	ch, err := sess.WatchRoster(ctx)
	if err != nil {
		t.Fatalf("WatchRoster: %v", err)
	}
	cancel()

	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return // goroutine exited with ctx, as it must
			}
		case <-deadline:
			t.Fatal("watcher channel still open 2s after cancel")
		}
	}
}

func TestRestartPluginPostsToKernel(t *testing.T) {
	sess, f := newTestServer(t)

	if err := sess.RestartPlugin(testCtx(t), "todo"); err != nil {
		t.Fatalf("RestartPlugin: %v", err)
	}
	got := f.kernel.restarted()
	if len(got) != 1 || got[0] != "todo" {
		t.Errorf("kernel saw restarts %v, want [todo]", got)
	}
}

func TestRestartUnknownPluginIsNotFound(t *testing.T) {
	sess, _ := newTestServer(t)

	err := sess.RestartPlugin(testCtx(t), "nope")
	if err == nil {
		t.Fatal("RestartPlugin of an unknown id succeeded")
	}
	if got := ExitCode(err); got != ExitNotFound {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitNotFound, err)
	}
}

func TestRestartPluginWithoutKernelIsUnreachable(t *testing.T) {
	sess, _ := newTestServer(t, withoutKernel())

	err := sess.RestartPlugin(testCtx(t), "todo")
	if err == nil {
		t.Fatal("RestartPlugin succeeded with the kernel down")
	}
	if got := ExitCode(err); got != ExitUnreachable {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitUnreachable, err)
	}
}

func TestLogSourcesUseTheKernelsPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sess, _ := newTestServer(t, withKernelPlugins(kernelPlugin{
		ID: "todo", Name: "Todo", State: "up", LogPath: "/var/log/vibecare/todo.log",
	}))

	got, err := sess.LogSources(testCtx(t))
	if err != nil {
		t.Fatalf("LogSources: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d sources, want core + todo: %+v", len(got), got)
	}
	wantCore := filepath.Join(home, ".vibecare", "logs", "server.log")
	if got[0].ID != "core" || got[0].Path != wantCore {
		t.Errorf("core source = %+v, want id core path %q", got[0], wantCore)
	}
	if got[1].ID != "todo" || got[1].Path != "/var/log/vibecare/todo.log" {
		t.Errorf("plugin source = %+v, want the kernel's log_path", got[1])
	}
}

// An older core reports no log_path. The convention is the fallback, never
// the first choice.
func TestLogSourcesFallBackToTheConvention(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sess, _ := newTestServer(t, withKernelPlugins(kernelPlugin{
		ID: "todo", Name: "Todo", State: "up",
	}))

	got, err := sess.LogSources(testCtx(t))
	if err != nil {
		t.Fatalf("LogSources: %v", err)
	}
	want := filepath.Join(home, ".vibecare", "logs", "plugins", "todo.log")
	if len(got) != 2 || got[1].Path != want {
		t.Fatalf("plugin source = %+v, want path %q", got, want)
	}
}

func TestLogSourceByID(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sess, _ := newTestServer(t)

	core, err := sess.LogSource(testCtx(t), "core")
	if err != nil {
		t.Fatalf("LogSource(core): %v", err)
	}
	if core.Path != filepath.Join(home, ".vibecare", "logs", "server.log") {
		t.Errorf("core path = %q", core.Path)
	}

	if _, err := sess.LogSource(testCtx(t), "todo"); err != nil {
		t.Fatalf("LogSource(todo): %v", err)
	}

	_, err = sess.LogSource(testCtx(t), "nope")
	if err == nil {
		t.Fatal("LogSource of an unknown id succeeded")
	}
	if got := ExitCode(err); got != ExitNotFound {
		t.Errorf("ExitCode = %d, want %d (err: %v)", got, ExitNotFound, err)
	}
}

// Logs are the one thing that has to work when everything else is broken, so
// a kernel that never answers still yields core's own log.
func TestLogSourcesWithoutKernelStillYieldCore(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	sess, _ := newTestServer(t, withoutKernel())

	got, err := sess.LogSources(testCtx(t))
	if err != nil {
		t.Fatalf("LogSources: %v", err)
	}
	if len(got) == 0 || got[0].ID != "core" {
		t.Fatalf("got %+v, want core first", got)
	}
	// The stream still knows the plugin exists; only its path is a guess.
	if len(got) != 2 || got[1].ID != "todo" {
		t.Fatalf("got %+v, want the streamed plugin too", got)
	}
	want := filepath.Join(home, ".vibecare", "logs", "plugins", "todo.log")
	if got[1].Path != want {
		t.Errorf("plugin path = %q, want %q", got[1].Path, want)
	}
}
