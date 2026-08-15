package kernel

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// maxPluginLogBytes is the size at which a plugin's log rotates. Two files
// per plugin bound the total at twice this with no timer, no sweeper and no
// external dependency — the cheapest thing that still guarantees a crashed
// plugin's last words survive. It is a var rather than a const purely so
// tests can shrink it; the value here is the contract.
var maxPluginLogBytes int64 = 8 << 20

// errNoLogsDir is what a supervisor with no logs directory configured gets
// back. It is an ordinary error precisely so the spawn path can shrug it
// off — see newPluginLog's contract.
var errNoLogsDir = errors.New("no logs directory configured")

// pluginLogPath is the single place the on-disk convention lives. The
// registry publishes what it returns instead of expecting readers to
// rebuild it, so this layout can change later without breaking any of them.
//
// An empty logsDir yields an empty path rather than a relative one: a
// relative path would scatter log files across whatever working directory
// core happened to be started from.
func pluginLogPath(logsDir, id string) string {
	if logsDir == "" {
		return ""
	}
	return filepath.Join(logsDir, "plugins", id+".log")
}

// pluginLog is one plugin's append-only output file, rotating in place at
// maxPluginLogBytes and keeping exactly one previous generation.
//
// Rotation is checked on write rather than on a timer: a plugin that never
// writes never needs anything done to it, and a plugin that floods is
// bounded at the moment it floods rather than up to a tick later.
type pluginLog struct {
	path string

	// mu guards f and size. The supervisor points BOTH of the child's
	// descriptors at one pluginLog, so concurrent writes are guaranteed by
	// construction rather than merely possible, and this lock is what keeps
	// a line written to stderr from landing inside a line written to stdout.
	mu   sync.Mutex
	f    *os.File
	size int64
}

// newPluginLog opens <logsDir>/plugins/<id>.log for appending, creating the
// directory if needed.
//
// It returns a nil writer alongside any error, and the caller is expected to
// carry on without one: losing the log costs a diagnostic record, while
// refusing to spawn would cost the plugin itself. Close is nil-safe for
// exactly that reason.
func newPluginLog(logsDir, id string) (*pluginLog, error) {
	path := pluginLogPath(logsDir, id)
	if path == "" {
		return nil, errNoLogsDir
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return nil, err
	}
	// Start from the size on disk, not zero: a restart must count against
	// the same budget the previous run was filling, or a plugin that
	// crash-loops would never rotate at all.
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	return &pluginLog{path: path, f: f, size: st.Size()}, nil
}

func (l *pluginLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return 0, os.ErrClosed
	}
	// Only a non-empty file is worth rotating: a single write larger than
	// the entire threshold would otherwise rotate an empty file on every
	// call and still have to be written through afterwards.
	if l.size > 0 && l.size+int64(len(p)) > maxPluginLogBytes {
		if err := l.rotateLocked(); err != nil {
			return 0, err
		}
	}
	n, err := l.f.Write(p)
	l.size += int64(n)
	return n, err
}

// rotateLocked closes the live file, moves it aside and opens a fresh one.
// Callers must hold l.mu.
//
// Any failure past the close leaves l.f nil rather than a closed handle, so
// later writes fail with ErrClosed instead of being aimed at a descriptor
// the kernel may already have handed to something else.
func (l *pluginLog) rotateLocked() error {
	if err := l.f.Close(); err != nil {
		l.f = nil
		return err
	}
	l.f = nil
	// Rename replaces any existing .1 in one step, which is the whole of
	// the single-generation policy: there is never a third file to prune.
	if err := os.Rename(l.path, l.path+".1"); err != nil {
		return err
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	l.f, l.size = f, 0
	return nil
}

// Close is idempotent and nil-safe. Both matter: the supervisor closes the
// log from its process-exit path, which a spawn that failed to open one in
// the first place also runs through.
func (l *pluginLog) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	return err
}
