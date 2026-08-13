package kernel

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"
)

// writeScript creates an executable shell script inside dir and returns the
// relative exec path a manifest would use.
func writeScript(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "plugin.sh")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return "./plugin.sh"
}

// newSup builds a supervisor over a single script-backed plugin and returns
// it along with the registry and the plugin's directory.
func newSup(t *testing.T, id, body string) (*Supervisor, *Registry, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	exec := writeScript(t, dir, body)

	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: id, Name: id, Exec: exec, UI: "webview", Dir: dir})

	s := NewSupervisor(reg, filepath.Join(root, "core.sock"), filepath.Join(root, "data"), zap.NewNop())
	return s, reg, dir
}

// waitState polls until the plugin reaches want, or fails the test.
func waitState(t *testing.T, reg *Registry, id string, want State, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if got, _ := reg.State(id); got == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	got, _ := reg.State(id)
	t.Fatalf("state = %v after %v, want %v", got, within, want)
}

func TestBackoffDelay(t *testing.T) {
	want := []time.Duration{
		time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second,
		16 * time.Second, 32 * time.Second, 60 * time.Second, 60 * time.Second,
	}
	for i, w := range want {
		if got := backoffDelay(i + 1); got != w {
			t.Errorf("backoffDelay(%d) = %v, want %v", i+1, got, w)
		}
	}
	if got := backoffDelay(0); got != time.Second {
		t.Errorf("backoffDelay(0) = %v, want 1s (defensive floor)", got)
	}
}

// The three spawn env vars and the working directory are the entire
// contract between core and a plugin process.
func TestSpawnEnvironmentAndWorkingDir(t *testing.T) {
	s, _, dir := newSup(t, "alpha", `
env | grep '^VIBECARE_' | sort > "$PWD/env.txt"
pwd > "$PWD/cwd.txt"
sleep 30
`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	// Wait for cwd.txt, not env.txt: the script writes env.txt first via a
	// pipeline (env | grep | sort) and cwd.txt second via a plain redirect.
	// Because the shell runs each line to completion before starting the
	// next, cwd.txt only appears once env.txt's redirect has been fully
	// written and closed. Polling for env.txt directly races the pipeline:
	// Stat can observe the truncated file the instant the shell opens it,
	// before grep/sort have flushed anything into it.
	envPath := filepath.Join(dir, "env.txt")
	cwdPath := filepath.Join(dir, "cwd.txt")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(cwdPath); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	b, err := os.ReadFile(envPath)
	if err != nil {
		t.Fatalf("plugin never ran: %v", err)
	}
	got := string(b)
	for _, want := range []string{"VIBECARE_PLUGIN_ID=alpha", "VIBECARE_SOCKET=", "VIBECARE_DATA_DIR="} {
		if !strings.Contains(got, want) {
			t.Errorf("env missing %q; got:\n%s", want, got)
		}
	}
	if strings.Count(got, "VIBECARE_") != 3 {
		t.Errorf("expected exactly 3 VIBECARE_ vars, got:\n%s", got)
	}

	cwd, err := os.ReadFile(cwdPath)
	if err != nil {
		t.Fatal(err)
	}
	// macOS resolves TempDir through /private; compare resolved paths.
	wantDir, _ := filepath.EvalSymlinks(dir)
	gotDir, _ := filepath.EvalSymlinks(strings.TrimSpace(string(cwd)))
	if gotDir != wantDir {
		t.Errorf("cwd = %q, want the plugin's own directory %q", gotDir, wantDir)
	}
}

// Core creates the data dir BEFORE spawning, so a plugin can open its store
// on the first line of main without checking.
func TestDataDirCreatedBeforeSpawn(t *testing.T) {
	s, _, dir := newSup(t, "alpha", `
[ -d "$VIBECARE_DATA_DIR" ] && echo yes > "$PWD/ok.txt"
sleep 30
`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(filepath.Join(dir, "ok.txt")); err == nil && strings.TrimSpace(string(b)) == "yes" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("VIBECARE_DATA_DIR did not exist when the plugin started")
}

// A plugin that never calls Register is wedged, not merely slow. It is
// killed and the attempt counts as a failed start.
func TestRegistrationTimeoutKillsPlugin(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", "sleep 60")
	registrationTimeout = 200 * time.Millisecond
	// The backoff ladder must be shrunk too: at the 1s default, five failed
	// starts cost 1+2+4+8 = 15s of sleeps on top of the five timeouts, which
	// alone exceeds this test's deadline.
	backoffScale = time.Millisecond
	t.Cleanup(func() {
		registrationTimeout = 10 * time.Second
		backoffScale = time.Second
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	// Never registers -> killed -> restarted -> killed ... -> failed.
	waitState(t, reg, "alpha", StateFailed, 15*time.Second)
	if got := reg.Snapshot()[0].Restarts; got < maxFailedStarts-1 {
		t.Errorf("restarts = %d, want at least %d before failing", got, maxFailedStarts-1)
	}
}

// NotifyRegistered is what cancels the timeout; a registered plugin is left
// alone even though the script does nothing but sleep.
func TestRegisteredPluginIsNotKilled(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", "sleep 30")
	registrationTimeout = 200 * time.Millisecond
	t.Cleanup(func() { registrationTimeout = 10 * time.Second })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	time.Sleep(50 * time.Millisecond)
	s.NotifyRegistered("alpha")
	reg.SetState("alpha", StateUp, "")

	time.Sleep(600 * time.Millisecond)
	if got, _ := reg.State("alpha"); got != StateUp {
		t.Fatalf("state = %v, want the registered plugin left running", got)
	}
}

// Five consecutive bad starts stop the ladder: the plugin is marked failed,
// stays visible in the roster with its exit reason, and is not restarted
// automatically.
func TestFailedAfterMaxBadStarts(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", "exit 3")
	backoffScale = time.Millisecond // 1ms,2ms,4ms... instead of 1s,2s,4s
	t.Cleanup(func() { backoffScale = time.Second })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	waitState(t, reg, "alpha", StateFailed, 10*time.Second)
	if d := reg.Snapshot()[0].Detail; !strings.Contains(d, "3") {
		t.Errorf("detail = %q, want it to carry the exit reason", d)
	}
}

// The dashboard's restart button must work from failed — that is how a
// failed plugin becomes recoverable without restarting core.
func TestManualRestartRecoversFromFailed(t *testing.T) {
	s, reg, dir := newSup(t, "alpha", "exit 3")
	backoffScale = time.Millisecond
	t.Cleanup(func() { backoffScale = time.Second })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())
	waitState(t, reg, "alpha", StateFailed, 10*time.Second)

	// Fix the plugin, then restart it by hand.
	writeScript(t, dir, "sleep 30")
	if err := s.Restart("alpha"); err != nil {
		t.Fatalf("Restart: %v", err)
	}
	waitState(t, reg, "alpha", StateStarting, 3*time.Second)
}

func TestRestartUnknownPluginErrors(t *testing.T) {
	s, _, _ := newSup(t, "alpha", "sleep 30")
	if err := s.Restart("ghost"); err == nil {
		t.Fatal("expected an error restarting an unknown plugin")
	}
}

// Stop must terminate a plugin that ignores SIGTERM, within the grace
// period, rather than hanging core's shutdown.
func TestStopKillsUnresponsivePlugin(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", `
trap '' TERM
sleep 60
`)
	shutdownGrace = 300 * time.Millisecond
	t.Cleanup(func() { shutdownGrace = 5 * time.Second })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	time.Sleep(200 * time.Millisecond)

	done := make(chan struct{})
	go func() { s.Stop(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop hung on a plugin that ignores SIGTERM")
	}
	if got, _ := reg.State("alpha"); got == StateUp {
		t.Errorf("state = %v after Stop", got)
	}
}

// After Stop, a plugin exit must NOT trigger the restart ladder.
func TestStopPreventsRestart(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", "sleep 30")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	time.Sleep(200 * time.Millisecond)
	s.Stop(context.Background())

	before := reg.Snapshot()[0].Restarts
	time.Sleep(500 * time.Millisecond)
	if after := reg.Snapshot()[0].Restarts; after != before {
		t.Fatalf("restarts went %d -> %d after Stop", before, after)
	}
}
