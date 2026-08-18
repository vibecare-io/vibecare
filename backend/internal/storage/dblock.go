package storage

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// errLockHeld reports that another process holds the lock. Platform implementations of
// tryLockFile return it; AcquireDBLock turns it into an *ErrLocked.
var errLockHeld = errors.New("lock held by another process")

// ErrLocked is returned when another process already has the database.
type ErrLocked struct {
	Path string
	// HolderPID is the process holding the lock, or 0 when it could not be read. It comes
	// from the lock file's contents, which is advisory - the lock itself belongs to the
	// kernel.
	HolderPID int
}

func (e *ErrLocked) Error() string {
	if e.HolderPID == 0 {
		return fmt.Sprintf("another vibecare-server already has %s open - stop it, or run with --db <other path>", e.Path)
	}
	return fmt.Sprintf("another vibecare-server (pid %d) already has %s open - stop it, or run with --db <other path>",
		e.HolderPID, e.Path)
}

// DBLock is an exclusive claim on a database, held for as long as the process lives.
type DBLock struct {
	file *os.File
	path string
}

// AcquireDBLock takes an exclusive advisory lock on dbPath, so that only one server runs a
// scheduler against it. Several servers sharing a database each run their own scheduler
// loop and race over the same next_execution column, which is silent, hard to spot, and
// looks exactly like a scheduling bug.
//
// The lock lives on a sidecar file, <dbPath>.lock, and is held by the kernel: it is
// released when the process exits for any reason, including a crash or SIGKILL, so a dead
// holder never locks a database out. Readers - sqlite3, litecli, `just inspect-db` - never
// take it and are never refused.
//
// Returns *ErrLocked if another process holds the database.
func AcquireDBLock(dbPath string) (*DBLock, error) {
	lockPath := dbPath + ".lock"

	// The lock file is created once and never removed. Deleting it on release would race:
	// another process can hold the lock on the deleted inode while a third creates a fresh
	// file and locks that one instead.
	file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open lock file %s: %w", lockPath, err)
	}

	if err := tryLockFile(file); err != nil {
		holder := readHolderPID(file)
		file.Close()
		if errors.Is(err, errLockHeld) {
			return nil, &ErrLocked{Path: dbPath, HolderPID: holder}
		}
		return nil, fmt.Errorf("failed to lock %s: %w", lockPath, err)
	}

	if err := writeHolderPID(file); err != nil {
		unlockFile(file)
		file.Close()
		return nil, fmt.Errorf("failed to record pid in %s: %w", lockPath, err)
	}

	return &DBLock{file: file, path: dbPath}, nil
}

// Release drops the lock. It is safe to call more than once, and safe to defer.
func (l *DBLock) Release() error {
	if l == nil || l.file == nil {
		return nil
	}

	file := l.file
	l.file = nil

	if err := unlockFile(file); err != nil {
		file.Close()
		return fmt.Errorf("failed to unlock %s: %w", file.Name(), err)
	}
	return file.Close()
}

// writeHolderPID records who holds the lock, for the error message a blocked server prints.
func writeHolderPID(file *os.File) error {
	if err := file.Truncate(0); err != nil {
		return err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if _, err := file.WriteString(strconv.Itoa(os.Getpid()) + "\n"); err != nil {
		return err
	}
	return file.Sync()
}

// readHolderPID reads the pid the holder recorded. A missing or unreadable pid is not an
// error: the lock is real either way, and the pid only improves the message.
func readHolderPID(file *os.File) int {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return 0
	}

	buf := make([]byte, 32)
	n, err := file.Read(buf)
	if n == 0 || (err != nil && err != io.EOF) {
		return 0
	}

	pid, err := strconv.Atoi(strings.TrimSpace(string(buf[:n])))
	if err != nil {
		return 0
	}
	return pid
}
