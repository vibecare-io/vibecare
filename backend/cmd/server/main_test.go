package main

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// resolvePluginsDirs is what makes a brew-installed VibeCare find the
// plugins that shipped with it. The binary lives at
// VibeCare.app/Contents/Resources/vibecare-server and its plugins sit in a
// `plugins` directory right beside it, so the server locates them from its
// own path rather than from anything baked into the LaunchAgent — which
// would hard-code an install location the cask is free to change.

func TestResolvePluginsDirsFlagWins(t *testing.T) {
	// A source checkout: `just run` passes --plugins-dir ../plugins and must
	// get exactly that, with no second directory quietly merged in. A dev
	// debugging one tree does not want ~/.vibecare/plugins-v2 in the mix.
	user, bundled := resolvePluginsDirs("/somewhere/plugins", t.TempDir(), "/home/u")
	if user != "/somewhere/plugins" || bundled != "" {
		t.Fatalf("got (%q, %q), want the flag alone", user, bundled)
	}
}

// Even when a sibling plugins dir exists, an explicit flag still means
// "only this one" — otherwise running the packaged binary against a test
// tree would silently pick up the shipped plugins too.
func TestResolvePluginsDirsFlagSuppressesBundled(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(exeDir, "plugins"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, bundled := resolvePluginsDirs("/somewhere/plugins", exeDir, "/home/u"); bundled != "" {
		t.Fatalf("bundled = %q, want none when --plugins-dir is explicit", bundled)
	}
}

func TestResolvePluginsDirsFindsBundledBesideExecutable(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(exeDir, "plugins"), 0o755); err != nil {
		t.Fatal(err)
	}

	user, bundled := resolvePluginsDirs("", exeDir, "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if want := filepath.Join(exeDir, "plugins"); bundled != want {
		t.Fatalf("bundled = %q, want %q", bundled, want)
	}
}

// A source build (go run ./cmd/server) has no plugins dir beside the
// binary. Reporting one anyway would point discovery at Go's build cache.
func TestResolvePluginsDirsNoBundledWhenAbsent(t *testing.T) {
	user, bundled := resolvePluginsDirs("", t.TempDir(), "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if bundled != "" {
		t.Fatalf("bundled = %q, want none", bundled)
	}
}

// A *file* named `plugins` beside the binary is not a plugins directory.
// Passing it on would turn a stray file into a scan error at startup.
func TestResolvePluginsDirsIgnoresNonDirectory(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(exeDir, "plugins"), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, bundled := resolvePluginsDirs("", exeDir, "/home/u"); bundled != "" {
		t.Fatalf("bundled = %q, want none for a non-directory", bundled)
	}
}

// os.Executable can fail, and a server that refuses to start because it
// could not find an optional directory would be worse than one with no
// bundled plugins. An empty exeDir just means "no bundled dir".
func TestResolvePluginsDirsToleratesUnknownExeDir(t *testing.T) {
	user, bundled := resolvePluginsDirs("", "", "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if bundled != "" {
		t.Fatalf("bundled = %q, want none", bundled)
	}
}

// A second server sharing a database is not a hypothetical: three of them ran for four
// days against ~/.vibecare/vibecare.db, each on its own port, each running a scheduler
// loop, racing over the same next_execution column. The port check cannot catch that -
// --port is exactly what those servers were given - so the guard is on the database, and
// this test runs the real binary twice on different ports to prove it.
func TestSecondServerOnTheSameDatabaseRefusesToStart(t *testing.T) {
	if testing.Short() {
		t.Skip("builds and runs the server binary")
	}

	binary := buildServer(t)
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "vibecare.db")
	pluginsDir := filepath.Join(dir, "plugins")
	if err := os.MkdirAll(pluginsDir, 0755); err != nil {
		t.Fatalf("creating empty plugins dir: %v", err)
	}

	// Port 0 on both: the two servers never contend for a port, only for the database.
	args := []string{
		"--db", dbPath,
		"--port", "0",
		"--web-port", "0",
		"--plugins-dir", pluginsDir,
		"--enable-tracing=false",
	}

	first := exec.Command(binary, args...)
	first.Stdout, first.Stderr = io.Discard, io.Discard
	if err := first.Start(); err != nil {
		t.Fatalf("starting first server: %v", err)
	}
	t.Cleanup(func() {
		_ = first.Process.Kill()
		_ = first.Wait()
	})
	waitForLockHeldBy(t, dbPath, first.Process.Pid)

	second := exec.Command(binary, args...)
	output, err := second.CombinedOutput()

	if err == nil {
		_ = second.Process.Kill()
		t.Fatal("second server started against a database another server already holds")
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("second server should have exited non-zero, got: %v", err)
	}

	out := string(output)
	if !strings.Contains(out, dbPath) {
		t.Errorf("failure should name the database %q; output was:\n%s", dbPath, out)
	}
	if !strings.Contains(out, strconv.Itoa(first.Process.Pid)) {
		t.Errorf("failure should name the holding pid %d; output was:\n%s", first.Process.Pid, out)
	}
}

// buildServer compiles the server under test, so the test exercises the real startup path
// rather than a re-implementation of it.
func buildServer(t *testing.T) string {
	t.Helper()

	binary := filepath.Join(t.TempDir(), "vibecare-server")
	build := exec.Command("go", "build", "-o", binary, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building server: %v\n%s", err, out)
	}
	return binary
}

// waitForLockHeldBy blocks until the server has taken the database lock, which is the
// point after which a second server must be refused.
func waitForLockHeldBy(t *testing.T, dbPath string, pid int) {
	t.Helper()

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if content, err := os.ReadFile(dbPath + ".lock"); err == nil {
			if strings.TrimSpace(string(content)) == strconv.Itoa(pid) {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("server %d never took the lock on %s", pid, dbPath)
}
