package kernel

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
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

	s := NewSupervisor(reg, filepath.Join(root, "core.sock"),
		filepath.Join(root, "data"), filepath.Join(root, "logs"), zap.NewNop())
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
	// "exit status 3" specifically, not just Contains(d, "3"): a substring
	// check on a bare "3" would also pass on an unrelated detail like "13
	// consecutive failed starts", which defeats the point of the assertion.
	if d := reg.Snapshot()[0].Detail; !strings.Contains(d, "exit status 3") {
		t.Errorf("detail = %q, want it to carry the exit reason (exit status 3)", d)
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
//
// The fixture must be unkillable by SIGTERM in a way that actually forces
// SIGKILL escalation: `trap ” TERM` only protects the shell itself, and
// Stop signals the whole process group, so a plain `sleep 60` child (not
// trapping anything) would still receive SIGTERM directly and exit well
// inside the grace window — the escalation path would never run and the
// test would pass regardless of whether SIGKILL escalation exists at all.
// A tight busy loop has no separate signal-killable child, so nothing in
// the group dies on SIGTERM; only SIGKILL (untrappable) can end it.
func TestStopKillsUnresponsivePlugin(t *testing.T) {
	s, _, dir := newSup(t, "alpha", `
trap '' TERM
touch "$PWD/trap-installed"
while :; do :; done
`)
	shutdownGrace = 300 * time.Millisecond
	t.Cleanup(func() { shutdownGrace = 5 * time.Second })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)

	// Wait for the script itself to confirm its trap is installed, rather
	// than a fixed sleep or a pid check. Neither is enough: a pid appears
	// the instant cmd.Start() returns from the fork+exec syscall, but the
	// child still has to be scheduled, load /bin/sh, and execute its first
	// line before "trap '' TERM" actually takes effect. Signaling before
	// that line runs hits the shell's default SIGTERM disposition
	// (terminate) despite the trap being present later in the script —
	// confirmed by a standalone repro: sending SIGTERM immediately after
	// spawn kills a script identical to this one, while waiting even 200ms
	// first lets it survive as expected. Only a signal from the script's
	// own execution proves the trap line has actually run.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(dir, "trap-installed")); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(dir, "trap-installed")); err != nil {
		t.Fatal("plugin never signaled that its TERM trap was installed")
	}

	start := time.Now()
	done := make(chan struct{})
	go func() { s.Stop(context.Background()); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop hung on a plugin that ignores SIGTERM")
	}
	// The only way Stop can return this quickly against a plugin that
	// never dies on SIGTERM is if SIGKILL escalation actually ran and
	// killed it. (Stop unconditionally marks every plugin StateDown before
	// it returns, so asserting on final registry state here would be
	// vacuous — elapsed time against shutdownGrace is the real proof that
	// escalation, not a graceful exit, is what ended the process.)
	//
	// Note this proves *an* escalation path in Stop's call graph killed the
	// process, not specifically that terminate() (Stop's own SIGTERM/grace/
	// SIGKILL sequence) did: Stop calls cancel() after its own escalation
	// attempt, and every plugin runOnce spawns also has a Finding-3
	// cancellation-watcher goroutine armed against that same ctx, which
	// would independently SIGKILL an unresponsive process too. Both were
	// verified disabled together during Finding 4's review — see the task
	// report. TestTerminateEscalatesToSIGKILL below isolates terminate()
	// specifically, with that watcher permanently disarmed, so between the
	// two tests both "Stop's shutdown doesn't hang" and "terminate() is
	// what does the escalating" are actually covered.
	if elapsed := time.Since(start); elapsed < shutdownGrace {
		t.Fatalf("Stop returned after %v, want at least shutdownGrace (%v): SIGKILL escalation did not run", elapsed, shutdownGrace)
	}
}

// terminate() is Stop's per-plugin SIGTERM-then-grace-then-SIGKILL
// escalation, factored out specifically so it can be driven in isolation
// here. TestStopKillsUnresponsivePlugin above proves Stop's shutdown
// doesn't hang on an unresponsive plugin, but it can't isolate terminate()
// from the Finding-3 cancellation watcher: Stop always calls cancel() after
// its own escalation attempt, and that watcher — armed for every plugin
// runOnce spawns — would independently SIGKILL the same unresponsive
// process, so that test alone doesn't prove terminate()'s own SIGKILL is
// what did the work.
//
// This test drives runOnce directly with context.Background(), which is
// never cancelled for the lifetime of the test. That permanently disarms
// the cancellation watcher (it only ever fires on ctx.Done()), making
// terminate() the only possible source of a kill here.
func TestTerminateEscalatesToSIGKILL(t *testing.T) {
	s, reg, dir := newSup(t, "alpha", `
trap '' TERM
touch "$PWD/trap-installed"
while :; do :; done
`)
	shutdownGrace = 300 * time.Millisecond
	t.Cleanup(func() { shutdownGrace = 5 * time.Second })

	m, ok := reg.Manifest("alpha")
	if !ok {
		t.Fatal("manifest not found")
	}
	go func() {
		_ = s.runOnce(context.Background(), m)
	}()

	// Same reasoning as TestStopKillsUnresponsivePlugin: wait for the
	// script's own confirmation that its trap is installed, not a pid or a
	// fixed sleep — a pid only proves fork+exec happened, not that the
	// child has executed a line of its own script yet.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(dir, "trap-installed")); err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(dir, "trap-installed")); err != nil {
		t.Fatal("plugin never signaled that its TERM trap was installed")
	}

	s.mu.Lock()
	ps := s.procs["alpha"]
	pid := 0
	if ps != nil {
		pid = ps.pid
	}
	s.mu.Unlock()
	if ps == nil || pid == 0 {
		t.Fatal("plugin has no pid yet")
	}

	start := time.Now()
	s.terminate(ps, pid)
	if elapsed := time.Since(start); elapsed < shutdownGrace {
		t.Fatalf("terminate returned after %v, want at least shutdownGrace (%v): SIGKILL escalation did not run", elapsed, shutdownGrace)
	}

	select {
	case <-ps.exited:
	case <-time.After(2 * time.Second):
		t.Fatal("process was not reaped after terminate's SIGKILL")
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

// kill() must never signal a reaped procState, even if its pid field still
// holds a value that happens to name a real, live, signalable process —
// exactly what pid reuse looks like from the supervisor's point of view.
// This spawns a real bystander process (an innocent stand-in for "some
// unrelated process that happens to have been handed the reaped plugin's
// old pid"), deliberately assigns its pid to an already-reaped procState,
// and proves kill() leaves it alone. Without the ps.exited guard in kill(),
// this bystander — a real, alive, signalable process group — would be
// SIGKILLed by this call.
func TestKillRefusesReapedPid(t *testing.T) {
	root := t.TempDir()

	bystander := exec.Command("/bin/sh", "-c", "sleep 5")
	bystander.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := bystander.Start(); err != nil {
		t.Fatalf("spawn bystander: %v", err)
	}
	bystanderPID := bystander.Process.Pid
	t.Cleanup(func() {
		_ = syscall.Kill(-bystanderPID, syscall.SIGKILL)
		_ = bystander.Wait()
	})

	if err := syscall.Kill(bystanderPID, 0); err != nil {
		t.Fatalf("bystander not alive before test: %v", err)
	}

	// A real plugin, run to completion and reaped, exactly like Stop or
	// Restart would encounter one whose runOnce goroutine already returned.
	dir := filepath.Join(root, "alpha")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeScript(t, dir, "exit 0")

	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "alpha", Exec: "./plugin.sh", UI: "webview", Dir: dir})
	s := NewSupervisor(reg, filepath.Join(root, "core.sock"),
		filepath.Join(root, "data"), filepath.Join(root, "logs"), zap.NewNop())

	m, _ := reg.Manifest("alpha")
	if err := s.runOnce(context.Background(), m); err != nil {
		t.Fatalf("runOnce: %v", err)
	}

	ps := s.procs["alpha"]
	if ps == nil {
		t.Fatal("no procState recorded")
	}
	select {
	case <-ps.exited:
	default:
		t.Fatal("expected ps.exited to be closed after runOnce returned")
	}
	if ps.pid != 0 {
		t.Fatalf("pid = %d after Wait returned, want 0 (waitAndCleanup zeroes it)", ps.pid)
	}

	// Simulate pid reuse: the plugin's old pid slot now "belongs" to the
	// bystander, exactly as the OS is free to do the instant a pid is
	// reaped.
	ps.pid = bystanderPID
	s.kill(ps)

	// syscall.Kill(pid, 0) is NOT enough to check survival here: a
	// killed-but-unreaped child is a zombie, and signal 0 still succeeds
	// against a zombie's pid until this test's own deferred Wait() reaps
	// it. A non-blocking wait4 is the only way to tell "still running"
	// apart from "already killed, just not reaped yet."
	time.Sleep(50 * time.Millisecond)
	var status syscall.WaitStatus
	gotPID, err := syscall.Wait4(bystanderPID, &status, syscall.WNOHANG, nil)
	if err != nil {
		t.Fatalf("wait4: %v", err)
	}
	if gotPID == bystanderPID {
		t.Fatalf("bystander (pid %d) was signaled by kill() on a reaped procState: exited with status %v", bystanderPID, status)
	}
}
