package kernel

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"
)

// shrinkRotation lowers the rotation threshold for one test and restores it
// afterwards, so no test has to write eight megabytes to reach it.
func shrinkRotation(t *testing.T, n int64) {
	t.Helper()
	prev := maxPluginLogBytes
	maxPluginLogBytes = n
	t.Cleanup(func() { maxPluginLogBytes = prev })
}

func TestPluginLogPathConvention(t *testing.T) {
	if got, want := pluginLogPath("/var/logs", "alpha"), "/var/logs/plugins/alpha.log"; got != want {
		t.Errorf("pluginLogPath = %q, want %q", got, want)
	}
	// An unconfigured logs dir must not resolve to a relative path that
	// would scatter log files across whatever cwd core happens to have.
	if got := pluginLogPath("", "alpha"); got != "" {
		t.Errorf("pluginLogPath with no logs dir = %q, want empty", got)
	}
}

func TestPluginLogCreatesFileWithRestrictivePermissions(t *testing.T) {
	root := t.TempDir()
	lw, err := newPluginLog(root, "alpha")
	if err != nil {
		t.Fatalf("newPluginLog: %v", err)
	}
	defer lw.Close()

	if _, err := lw.Write([]byte("hello\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

	fi, err := os.Stat(pluginLogPath(root, "alpha"))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Errorf("log mode = %v, want 0600", perm)
	}
	di, err := os.Stat(filepath.Join(root, "plugins"))
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Errorf("dir mode = %v, want 0700", perm)
	}
}

// A restart opens the log again; the previous run's output must still be
// there, because the previous run is exactly the one being investigated.
func TestPluginLogAppendsAcrossReopen(t *testing.T) {
	root := t.TempDir()

	first, err := newPluginLog(root, "alpha")
	if err != nil {
		t.Fatalf("newPluginLog: %v", err)
	}
	if _, err := first.Write([]byte("run-1\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	second, err := newPluginLog(root, "alpha")
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if _, err := second.Write([]byte("run-2\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := second.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	b, err := os.ReadFile(pluginLogPath(root, "alpha"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got, want := string(b), "run-1\nrun-2\n"; got != want {
		t.Errorf("log = %q, want %q", got, want)
	}
}

func TestPluginLogRotation(t *testing.T) {
	tests := []struct {
		name      string
		threshold int64
		writes    []string
		live      string // expected <id>.log contents
		prev      string // expected <id>.log.1 contents; "" means absent
	}{
		{
			name:      "under threshold does not rotate",
			threshold: 32,
			writes:    []string{"aaaa", "bbbb"},
			live:      "aaaabbbb",
		},
		{
			name:      "write crossing threshold rotates first",
			threshold: 8,
			writes:    []string{"aaaa", "bbbb", "cccc"},
			live:      "cccc",
			prev:      "aaaabbbb",
		},
		{
			name:      "exactly at threshold does not rotate",
			threshold: 8,
			writes:    []string{"aaaa", "bbbb"},
			live:      "aaaabbbb",
		},
		{
			name:      "keeps exactly one generation",
			threshold: 4,
			writes:    []string{"1111", "2222", "3333", "4444"},
			live:      "4444",
			prev:      "3333",
		},
		{
			name:      "single oversized write does not spin",
			threshold: 4,
			writes:    []string{"aaaaaaaaaaaa"},
			live:      "aaaaaaaaaaaa",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			shrinkRotation(t, tt.threshold)
			root := t.TempDir()
			lw, err := newPluginLog(root, "alpha")
			if err != nil {
				t.Fatalf("newPluginLog: %v", err)
			}
			defer lw.Close()

			for _, w := range tt.writes {
				if n, err := lw.Write([]byte(w)); err != nil || n != len(w) {
					t.Fatalf("write %q = (%d, %v)", w, n, err)
				}
			}

			path := pluginLogPath(root, "alpha")
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read live: %v", err)
			}
			if string(b) != tt.live {
				t.Errorf("live log = %q, want %q", b, tt.live)
			}

			prev, err := os.ReadFile(path + ".1")
			switch {
			case tt.prev == "":
				if err == nil {
					t.Errorf("unexpected rotated file: %q", prev)
				}
			case err != nil:
				t.Fatalf("read rotated: %v", err)
			case string(prev) != tt.prev:
				t.Errorf("rotated log = %q, want %q", prev, tt.prev)
			}

			// Exactly two files, ever — that is the whole retention policy.
			entries, err := os.ReadDir(filepath.Join(root, "plugins"))
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) > 2 {
				t.Errorf("got %d log files, want at most 2", len(entries))
			}
		})
	}
}

// The supervisor points both of the child's descriptors at one writer, so
// concurrent writes are guaranteed rather than merely possible. Run under
// -race to make this meaningful.
func TestPluginLogConcurrentWrites(t *testing.T) {
	shrinkRotation(t, 64)
	root := t.TempDir()
	lw, err := newPluginLog(root, "alpha")
	if err != nil {
		t.Fatalf("newPluginLog: %v", err)
	}
	defer lw.Close()

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 64; j++ {
				if _, err := lw.Write([]byte("0123456789\n")); err != nil {
					t.Errorf("write: %v", err)
					return
				}
			}
		}()
	}
	wg.Wait()
}

// Logging must never be able to stop a plugin from starting, so the failure
// has to surface as a plain error the caller can shrug off.
func TestPluginLogUnwritableDirDegrades(t *testing.T) {
	root := t.TempDir()
	// A regular file where the plugins directory belongs: MkdirAll cannot
	// win against this even when the test runs as root.
	if err := os.WriteFile(filepath.Join(root, "plugins"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	lw, err := newPluginLog(root, "alpha")
	if err == nil {
		lw.Close()
		t.Fatal("newPluginLog succeeded with an unwritable directory")
	}
	if lw != nil {
		t.Fatal("newPluginLog returned a writer alongside an error")
	}
	// The nil writer is what the supervisor's error path holds; closing it
	// must not panic.
	if err := lw.Close(); err != nil {
		t.Errorf("Close on nil log = %v", err)
	}
}

func TestPluginLogCloseIsIdempotent(t *testing.T) {
	lw, err := newPluginLog(t.TempDir(), "alpha")
	if err != nil {
		t.Fatalf("newPluginLog: %v", err)
	}
	if err := lw.Close(); err != nil {
		t.Fatalf("first close: %v", err)
	}
	if err := lw.Close(); err != nil {
		t.Errorf("second close: %v", err)
	}
}

// The end-to-end claim: a spawned process's output reaches its own file,
// which is the entire reason any of this exists.
func TestSupervisorWritesSpawnedOutputToLogFile(t *testing.T) {
	s, _, _ := newSup(t, "alpha", `
echo "on stdout"
echo "on stderr" >&2
sleep 30
`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	path := pluginLogPath(s.logsDir, "alpha")

	deadline := time.Now().Add(3 * time.Second)
	var body string
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(path)
		if err == nil {
			body = string(b)
			if strings.Contains(body, "on stdout") && strings.Contains(body, "on stderr") {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("log %s did not capture both streams; got %q", path, body)
}

// A supervisor with no logs dir still spawns: stderr-only is a degraded
// mode, not a failure.
func TestSupervisorSpawnsWithoutLogsDir(t *testing.T) {
	s, reg, _ := newSup(t, "alpha", "sleep 30")
	s.logsDir = ""

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop(context.Background())

	waitState(t, reg, "alpha", StateStarting, 2*time.Second)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if snap := reg.Snapshot(); len(snap) == 1 && snap[0].PID > 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("plugin never spawned without a logs dir")
}

func TestSnapshotCarriesLogPath(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.SetLogsDir("/var/logs")
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})

	snap := reg.Snapshot()
	if len(snap) != 1 {
		t.Fatalf("got %d stats, want 1", len(snap))
	}
	if got, want := snap[0].LogPath, "/var/logs/plugins/alpha.log"; got != want {
		t.Errorf("LogPath = %q, want %q", got, want)
	}
}

// A registry that was never told where logs live reports no path at all,
// rather than a plausible-looking one that does not exist.
func TestSnapshotOmitsLogPathWhenUnset(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
	if got := reg.Snapshot()[0].LogPath; got != "" {
		t.Errorf("LogPath = %q, want empty", got)
	}
}

// The path is published rather than reconstructed by readers, so it has to
// be in the JSON the client actually reads.
func TestStatusJSONCarriesLogPath(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.SetLogsDir("/var/logs")
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})

	rec := httptest.NewRecorder()
	NewStatusHandler(reg, &fakeRestarter{}, nil).ServeHTTP(
		rec, httptest.NewRequest("GET", apiPluginsPath, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}

	var got struct {
		Plugins []map[string]any `json:"plugins"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.Plugins) != 1 {
		t.Fatalf("got %d plugins, want 1", len(got.Plugins))
	}
	if v, ok := got.Plugins[0]["log_path"]; !ok || v != "/var/logs/plugins/alpha.log" {
		t.Errorf("log_path = %v (present=%v), want /var/logs/plugins/alpha.log", v, ok)
	}
}
