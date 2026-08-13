package kernel

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"go.uber.org/zap"
)

// Lifecycle timings. These are vars rather than consts purely so tests can
// shrink them; the values here are the contract.
var (
	// registrationTimeout is how long a plugin has to call Register after
	// being spawned before core concludes it is wedged and kills it.
	registrationTimeout = 10 * time.Second
	// shutdownGrace is how long a plugin has between SIGTERM and SIGKILL.
	shutdownGrace = 5 * time.Second
	// stableUptime is how long a plugin must stay up before its failed-start
	// counter resets. Past this, a death is a crash in service, not a
	// failure to start, and it earns the full backoff ladder again.
	stableUptime = 60 * time.Second
	// backoffScale is the base unit of the restart ladder.
	backoffScale = time.Second
)

// maxFailedStarts is how many consecutive bad starts before core stops
// trying. The plugin stays in the roster and the dashboard, marked failed,
// recoverable by the restart button.
const maxFailedStarts = 5

// backoffDelay returns the restart delay after n consecutive failed starts:
// 1s, 2s, 4s, 8s, 16s, 32s, then capped at 60s.
func backoffDelay(n int) time.Duration {
	if n < 1 {
		n = 1
	}
	if n > 7 {
		return 60 * backoffScale
	}
	d := backoffScale << (n - 1)
	if d > 60*backoffScale {
		d = 60 * backoffScale
	}
	return d
}

type procState struct {
	cmd *exec.Cmd
	// registered is closed by NotifyRegistered. A fresh channel is made for
	// every spawn attempt.
	registered chan struct{}
	// exited is closed by runOnce once cmd.Wait has returned. Stop waits on
	// this rather than polling cmd.ProcessState: Wait is concurrently in
	// flight inside runOnce, and reading ProcessState from another goroutine
	// is a data race that -race will flag.
	exited chan struct{}
	// intentional marks a kill this supervisor asked for (Stop or Restart),
	// so the loop can tell it apart from a crash.
	intentional bool
	// pid is cmd.Process.Pid, copied here under Supervisor.mu once Start
	// succeeds. Every reader (Stop, Restart, the registration watchdog) goes
	// through this field instead of cmd.Process: cmd.Start() writes that
	// field with no synchronization of its own, so reading it from another
	// goroutine while runOnce may still be inside Start() is a data race.
	// pid == 0 means "not started yet".
	pid int
}

// Supervisor owns every plugin process: it spawns them, gives each one its
// data dir and socket path, enforces the registration timeout, restarts
// them with backoff, and tears them down on shutdown.
type Supervisor struct {
	reg        *Registry
	socketPath string
	dataRoot   string
	log        *zap.Logger

	mu       sync.Mutex
	procs    map[string]*procState
	restartC map[string]chan struct{} // manual restart signal per plugin
	stopped  bool

	wg     sync.WaitGroup
	cancel context.CancelFunc
}

func NewSupervisor(reg *Registry, socketPath, dataRoot string, log *zap.Logger) *Supervisor {
	return &Supervisor{
		reg:        reg,
		socketPath: socketPath,
		dataRoot:   dataRoot,
		log:        log,
		procs:      map[string]*procState{},
		restartC:   map[string]chan struct{}{},
	}
}

// Start launches one supervision goroutine per discovered plugin.
func (s *Supervisor) Start(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	s.mu.Lock()
	s.cancel = cancel
	for _, m := range s.reg.Manifests() {
		s.restartC[m.ID] = make(chan struct{}, 1)
	}
	s.mu.Unlock()

	for _, m := range s.reg.Manifests() {
		s.wg.Add(1)
		go func(m Manifest) {
			defer s.wg.Done()
			s.supervise(ctx, m)
		}(m)
	}
}

// supervise is one plugin's entire lifecycle, start to finish. Keeping the
// whole state machine in a single goroutine is what keeps the ordering
// (spawn -> register -> up -> exit -> classify -> backoff) obvious.
func (s *Supervisor) supervise(ctx context.Context, m Manifest) {
	failures := 0

	for {
		if ctx.Err() != nil {
			return
		}

		startedAt := time.Now()
		exitErr := s.runOnce(ctx, m)
		if ctx.Err() != nil {
			return
		}

		s.mu.Lock()
		intentional := s.procs[m.ID] != nil && s.procs[m.ID].intentional
		stopped := s.stopped
		s.mu.Unlock()
		if stopped {
			return
		}

		reason := "exited"
		if exitErr != nil {
			reason = exitErr.Error()
		}

		if intentional {
			// A restart we asked for: don't punish the plugin for it.
			failures = 0
		} else {
			if time.Since(startedAt) >= stableUptime {
				// It ran fine for a while; this is a crash in service, so the
				// ladder starts over rather than continuing toward failed.
				failures = 0
			}
			failures++
			s.reg.SetState(m.ID, StateDown, reason)
		}

		if failures >= maxFailedStarts {
			s.reg.SetState(m.ID, StateFailed,
				fmt.Sprintf("%d consecutive failed starts; last: %s", failures, reason))
			// Park until a manual restart arrives (or core shuts down).
			select {
			case <-ctx.Done():
				return
			case <-s.restartChan(m.ID):
				failures = 0
				continue
			}
		}

		delay := backoffDelay(failures)
		if intentional {
			delay = 0
		}
		s.reg.IncRestarts(m.ID)
		select {
		case <-ctx.Done():
			return
		case <-s.restartChan(m.ID):
			failures = 0
		case <-time.After(delay):
		}
	}
}

// runOnce spawns the plugin, enforces the registration timeout, and blocks
// until the process exits. It returns the process's exit error, if any.
func (s *Supervisor) runOnce(ctx context.Context, m Manifest) error {
	dataDir := filepath.Join(s.dataRoot, m.ID)
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		s.reg.SetState(m.ID, StateDown, "create data dir: "+err.Error())
		return err
	}

	cmd := exec.Command(m.Exec)
	cmd.Dir = m.Dir
	// Exactly three variables, plus PATH/HOME so the process can find a
	// shell and its own home. Everything else a plugin needs comes from its
	// own directory or its data dir.
	cmd.Env = append(os.Environ(),
		"VIBECARE_SOCKET="+s.socketPath,
		"VIBECARE_PLUGIN_ID="+m.ID,
		"VIBECARE_DATA_DIR="+dataDir,
	)
	cmd.Stdout = os.Stderr // plugin stdout is diagnostic only; never parsed
	cmd.Stderr = os.Stderr
	// Own process group, so SIGKILL reaches children the plugin spawned.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	ps := &procState{cmd: cmd, registered: make(chan struct{}), exited: make(chan struct{})}
	s.mu.Lock()
	s.procs[m.ID] = ps
	s.mu.Unlock()

	s.reg.SetState(m.ID, StateStarting, "")
	if err := cmd.Start(); err != nil {
		s.reg.SetState(m.ID, StateDown, "spawn: "+err.Error())
		return err
	}

	// Publish the pid under the lock Stop and Restart also use, and check
	// whether Stop already swept the roster before this spawn finished. If
	// so, Stop's per-process loop had nothing to kill (pid was still 0 when
	// it looked), so this goroutine must kill its own just-started process
	// itself rather than leaking it past shutdown.
	s.mu.Lock()
	ps.pid = cmd.Process.Pid
	stopping := s.stopped
	s.mu.Unlock()

	s.reg.SetProcess(m.ID, cmd.Process.Pid)
	s.log.Info("plugin spawned", zap.String("plugin", m.ID), zap.Int("pid", cmd.Process.Pid))

	if stopping {
		s.kill(ps)
		err := cmd.Wait()
		close(ps.exited)
		return err
	}

	// Registration watchdog. A plugin that hasn't handshaken in time is
	// wedged; kill it and let the loop treat it as a failed start.
	watchdog := time.AfterFunc(registrationTimeout, func() {
		select {
		case <-ps.registered:
			return
		default:
		}
		s.log.Warn("plugin did not register in time; killing",
			zap.String("plugin", m.ID), zap.Duration("timeout", registrationTimeout))
		s.kill(ps)
	})
	defer watchdog.Stop()

	err := cmd.Wait()
	// Publish the exit exactly once, so Stop can observe it without racing
	// on cmd.ProcessState.
	close(ps.exited)
	return err
}

func (s *Supervisor) restartChan(id string) chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.restartC[id]
}

// NotifyRegistered is called by the Register RPC when a plugin completes
// the handshake. It disarms that spawn's registration watchdog.
func (s *Supervisor) NotifyRegistered(id string) {
	s.mu.Lock()
	ps := s.procs[id]
	s.mu.Unlock()
	if ps == nil {
		return
	}
	select {
	case <-ps.registered:
	default:
		close(ps.registered)
	}
}

// Restart terminates the plugin and asks its supervision loop to respawn
// immediately with a clean failure count. It works from any state,
// including failed — that is what makes the dashboard button useful.
func (s *Supervisor) Restart(id string) error {
	s.mu.Lock()
	ch, known := s.restartC[id]
	ps := s.procs[id]
	if ps != nil {
		ps.intentional = true
	}
	s.mu.Unlock()

	if !known {
		return fmt.Errorf("unknown plugin %q", id)
	}
	if ps != nil {
		s.kill(ps)
	}
	select {
	case ch <- struct{}{}:
	default: // a restart is already pending; one is enough
	}
	return nil
}

// stopTarget pairs a procState with the pid it had at the moment Stop
// snapshotted the roster, so the per-process goroutines below never have to
// read ps.cmd.Process (and race runOnce's unsynchronized write to it) again.
type stopTarget struct {
	ps  *procState
	pid int
}

// Stop tears every plugin down: SIGTERM, then SIGKILL after shutdownGrace.
// Callers should have already sent CoreMsg.Shutdown on the plugin streams
// (rpc.go owns those) so plugins get a chance to flush first.
func (s *Supervisor) Stop(ctx context.Context) {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return
	}
	s.stopped = true
	targets := make([]stopTarget, 0, len(s.procs))
	for _, ps := range s.procs {
		ps.intentional = true
		targets = append(targets, stopTarget{ps: ps, pid: ps.pid})
	}
	cancel := s.cancel
	s.mu.Unlock()

	var wg sync.WaitGroup
	for _, tgt := range targets {
		if tgt.pid == 0 {
			// Start() hadn't finished for this spawn attempt when Stop
			// looked. runOnce checks s.stopped itself right after Start
			// succeeds (under the same lock we just set s.stopped=true
			// under) and self-kills in that case, so there is nothing to do
			// here — just don't block Stop's return on it. s.wg.Wait()
			// below still waits for that goroutine to actually finish.
			continue
		}
		wg.Add(1)
		go func(ps *procState, pid int) {
			defer wg.Done()
			_ = syscall.Kill(-pid, syscall.SIGTERM)
			// runOnce closes ps.exited after cmd.Wait returns. Waiting on
			// that channel is the only race-free way to observe the exit —
			// cmd.Wait is already in flight there, so neither a second Wait
			// nor a read of cmd.ProcessState is safe from here.
			select {
			case <-ps.exited:
			case <-time.After(shutdownGrace):
				s.log.Warn("plugin ignored SIGTERM; killing", zap.Int("pid", pid))
				s.kill(ps)
			}
		}(tgt.ps, tgt.pid)
	}
	wg.Wait()

	if cancel != nil {
		cancel()
	}
	s.wg.Wait()

	for _, m := range s.reg.Manifests() {
		s.reg.SetState(m.ID, StateDown, "core shutting down")
	}
}

// kill SIGKILLs the process group, so anything the plugin spawned dies too.
// It reads ps.pid under the supervisor lock rather than ps.cmd.Process:
// runOnce writes that field with no synchronization of its own once Start
// succeeds, so any other goroutine reading it directly would race.
func (s *Supervisor) kill(ps *procState) {
	if ps == nil {
		return
	}
	s.mu.Lock()
	pid := ps.pid
	s.mu.Unlock()
	if pid == 0 {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}
