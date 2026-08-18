package storage

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestAcquireDBLock_SecondAcquireIsRefused is the guard itself: two servers pointed at one
// database must not both start.
func TestAcquireDBLock_SecondAcquireIsRefused(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vibecare.db")

	first, err := AcquireDBLock(dbPath)
	if err != nil {
		t.Fatalf("first acquire should succeed, got: %v", err)
	}
	defer first.Release()

	second, err := AcquireDBLock(dbPath)
	if err == nil {
		second.Release()
		t.Fatal("second acquire succeeded; the database is not guarded")
	}

	var locked *ErrLocked
	if !errors.As(err, &locked) {
		t.Fatalf("expected *ErrLocked, got %T: %v", err, err)
	}
	if locked.Path != dbPath {
		t.Errorf("ErrLocked.Path = %q, want %q", locked.Path, dbPath)
	}
}

// TestAcquireDBLock_ErrorNamesTheHolder - the error exists to tell a human which process to
// stop, so the PID has to survive into it.
func TestAcquireDBLock_ErrorNamesTheHolder(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vibecare.db")

	first, err := AcquireDBLock(dbPath)
	if err != nil {
		t.Fatalf("first acquire should succeed, got: %v", err)
	}
	defer first.Release()

	_, err = AcquireDBLock(dbPath)
	var locked *ErrLocked
	if !errors.As(err, &locked) {
		t.Fatalf("expected *ErrLocked, got %T: %v", err, err)
	}
	if locked.HolderPID != os.Getpid() {
		t.Errorf("HolderPID = %d, want this process %d", locked.HolderPID, os.Getpid())
	}

	msg := locked.Error()
	if !strings.Contains(msg, dbPath) {
		t.Errorf("error message %q should name the database path", msg)
	}
	if !strings.Contains(msg, strconv.Itoa(os.Getpid())) {
		t.Errorf("error message %q should name the holding pid", msg)
	}
}

// TestAcquireDBLock_ReleaseFreesIt covers the ordinary restart: stop the server, start it
// again.
func TestAcquireDBLock_ReleaseFreesIt(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vibecare.db")

	first, err := AcquireDBLock(dbPath)
	if err != nil {
		t.Fatalf("first acquire should succeed, got: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatalf("release failed: %v", err)
	}

	second, err := AcquireDBLock(dbPath)
	if err != nil {
		t.Fatalf("acquire after release should succeed, got: %v", err)
	}
	if err := second.Release(); err != nil {
		t.Fatalf("second release failed: %v", err)
	}
	// Release is deferred at call sites, and a double release must not be a crash.
	if err := second.Release(); err != nil {
		t.Errorf("release should be idempotent, second call returned: %v", err)
	}
}

// TestAcquireDBLock_DifferentDatabasesDoNotConflict keeps `--db /tmp/scratch.db` working as
// the supported way to run a second server.
func TestAcquireDBLock_DifferentDatabasesDoNotConflict(t *testing.T) {
	dir := t.TempDir()

	live, err := AcquireDBLock(filepath.Join(dir, "vibecare.db"))
	if err != nil {
		t.Fatalf("acquire on live db failed: %v", err)
	}
	defer live.Release()

	scratch, err := AcquireDBLock(filepath.Join(dir, "scratch.db"))
	if err != nil {
		t.Fatalf("a different database must not be blocked, got: %v", err)
	}
	defer scratch.Release()
}

// TestAcquireDBLock_AcrossProcesses is the test that matters. The incident this guards
// against was four separate processes, and an in-process check would also pass under a
// POSIX fcntl lock, which hands the same process a second lock without complaint.
func TestAcquireDBLock_AcrossProcesses(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vibecare.db")

	holder := startLockHolder(t, dbPath)

	_, err := AcquireDBLock(dbPath)
	if err == nil {
		t.Fatal("acquired a lock held by another process")
	}

	var locked *ErrLocked
	if !errors.As(err, &locked) {
		t.Fatalf("expected *ErrLocked, got %T: %v", err, err)
	}
	if locked.HolderPID != holder.pid {
		t.Errorf("HolderPID = %d, want the child process %d", locked.HolderPID, holder.pid)
	}
}

// TestAcquireDBLock_KilledHolderLeavesNothingBehind is why this uses flock rather than a pid
// file. The stale servers behind this guard had been orphaned for four days; a crashed or
// SIGKILLed holder must not lock the database out forever.
func TestAcquireDBLock_KilledHolderLeavesNothingBehind(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vibecare.db")

	holder := startLockHolder(t, dbPath)
	if _, err := AcquireDBLock(dbPath); err == nil {
		t.Fatal("lock should be held while the child is alive")
	}

	holder.kill(t)

	lock, err := AcquireDBLock(dbPath)
	if err != nil {
		t.Fatalf("a SIGKILLed holder should leave no lock behind, got: %v", err)
	}
	lock.Release()
}

// --- helper process plumbing ---

const (
	helperEnv     = "VIBECARE_DBLOCK_HELPER"
	helperPathEnv = "VIBECARE_DBLOCK_PATH"
)

type lockHolder struct {
	cmd *exec.Cmd
	pid int
}

// startLockHolder re-executes this test binary as a child that acquires the lock and then
// blocks, returning once the child confirms it holds it.
func startLockHolder(t *testing.T, dbPath string) *lockHolder {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess", "-test.timeout=90s")
	cmd.Env = append(os.Environ(), helperEnv+"=1", helperPathEnv+"="+dbPath)
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("starting lock holder: %v", err)
	}

	ready := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			if line := scanner.Text(); strings.HasPrefix(line, "locked ") {
				ready <- line
				return
			}
		}
		close(ready)
	}()

	select {
	case line, ok := <-ready:
		if !ok {
			t.Fatal("lock holder exited without acquiring the lock")
		}
		pid, err := strconv.Atoi(strings.TrimPrefix(line, "locked "))
		if err != nil {
			t.Fatalf("lock holder reported an unreadable pid in %q: %v", line, err)
		}
		if pid != cmd.Process.Pid {
			t.Fatalf("lock holder reported pid %d but was started as %d", pid, cmd.Process.Pid)
		}
		holder := &lockHolder{cmd: cmd, pid: pid}
		// Always reap the child, including when the test fails early - a leaked holder
		// sleeps on the test binary's stdout and stalls the package for a minute.
		t.Cleanup(holder.stop)
		return holder
	case <-time.After(30 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("timed out waiting for the lock holder to start")
		return nil
	}
}

func (h *lockHolder) kill(t *testing.T) {
	t.Helper()

	if err := h.cmd.Process.Signal(syscall.SIGKILL); err != nil {
		t.Fatalf("killing lock holder: %v", err)
	}
	// Wait for the kernel to reap it; the lock is gone once the process is.
	_ = h.cmd.Wait()
}

func (h *lockHolder) stop() {
	_ = h.cmd.Process.Kill()
	_ = h.cmd.Wait()
}

// TestHelperProcess is not a test. It runs only when re-executed by startLockHolder, holds
// the lock, and waits to be killed.
func TestHelperProcess(t *testing.T) {
	if os.Getenv(helperEnv) != "1" {
		t.Skip("helper process; only runs when re-executed by a lock test")
	}

	lock, err := AcquireDBLock(os.Getenv(helperPathEnv))
	if err != nil {
		t.Fatalf("helper failed to acquire the lock: %v", err)
	}
	defer lock.Release()

	os.Stdout.WriteString("locked " + strconv.Itoa(os.Getpid()) + "\n")

	// Hold it until the parent kills us. Sleeping (rather than blocking forever) keeps the
	// runtime's deadlock detector out of it and bounds a leaked child.
	time.Sleep(60 * time.Second)
}
