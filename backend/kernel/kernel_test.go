package kernel

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"
)

func testConfig(t *testing.T) Config {
	t.Helper()
	home := t.TempDir()

	// The unix socket path has to stay short: macOS (and GitHub's macOS
	// runners) caps sockaddr_un.sun_path at 104 bytes, and t.TempDir()'s
	// default location is a long, deeply-nested path
	// (/var/folders/.../T/<TestName>/NNN) under a $TMPDIR that is itself
	// already long — combined with a descriptive test function name, that
	// routinely blows past the limit and fails net.Listen("unix", ...)
	// with "invalid argument" on a completely healthy kernel. A short,
	// fixed prefix under /tmp sidesteps both the test name length and
	// whatever $TMPDIR happens to be set to.
	sockDir, err := os.MkdirTemp("/tmp", "vck")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sockDir) })

	return Config{
		PluginsDir:  filepath.Join(home, "plugins"),
		DataRoot:    filepath.Join(home, "data"),
		SocketPath:  filepath.Join(sockDir, "core.sock"),
		SessionPath: filepath.Join(home, "session"),
	}
}

func startKernel(t *testing.T, cfg Config) *Kernel {
	t.Helper()
	k, err := New(cfg, zap.NewNop())
	if err != nil {
		t.Fatal(err)
	}
	if err := k.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { k.Stop(context.Background()) })
	return k
}

func TestKernelBindsLoopbackAndUnixSocket(t *testing.T) {
	cfg := testConfig(t)
	k := startKernel(t, cfg)

	if !strings.HasPrefix(k.BaseURL(context.Background()), "http://127.0.0.1:") {
		t.Fatalf("BaseURL = %q, want a loopback origin with a kernel-assigned port", k.BaseURL(context.Background()))
	}
	if strings.HasSuffix(k.BaseURL(context.Background()), ":0") {
		t.Fatal("BaseURL still has the placeholder port; report the ACTUAL bound port")
	}

	fi, err := os.Stat(cfg.SocketPath)
	if err != nil {
		t.Fatalf("socket not created: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %v, want 0600", fi.Mode().Perm())
	}
}

// A SIGKILLed core leaves the socket file behind; the next start must not
// be blocked by it.
func TestKernelRemovesStaleSocket(t *testing.T) {
	cfg := testConfig(t)
	if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.SocketPath, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	startKernel(t, cfg) // must not error
}

func TestKernelHTTPRequiresAuth(t *testing.T) {
	k := startKernel(t, testConfig(t))

	resp, err := http.Get(k.BaseURL(context.Background()) + "/_core/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated dashboard = %d, want 401", resp.StatusCode)
	}
}

func TestKernelDashboardReachableWithToken(t *testing.T) {
	k := startKernel(t, testConfig(t))

	// Don't follow the post-handoff redirect; assert on the handoff itself.
	c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Get(k.BaseURL(context.Background()) + "/_core/status?" + tokenParam + "=" + k.Token())
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("code = %d, want 302 after the token handoff", resp.StatusCode)
	}

	req, _ := http.NewRequest("GET", k.BaseURL(context.Background())+"/_core/status", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: k.Token()})
	resp2, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("code = %d with a valid cookie, want 200", resp2.StatusCode)
	}
}

// /_core/* is reserved and must never be routed to a plugin, even if one
// somehow claimed a colliding path.
func TestCorePathsAreNotProxied(t *testing.T) {
	k := startKernel(t, testConfig(t))
	c := &http.Client{}

	req, _ := http.NewRequest("GET", k.BaseURL(context.Background())+"/_core/api/plugins", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: k.Token()})
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Fatalf("content-type = %q; /_core/* was routed somewhere other than the dashboard", ct)
	}
}

// Discovery happens in Start, so a manifest dropped in before boot appears
// in the roster with no registration step anywhere in core.
func TestKernelDiscoversPluginsAtStart(t *testing.T) {
	cfg := testConfig(t)
	dir := filepath.Join(cfg.PluginsDir, "alpha")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := "id: alpha\nname: Alpha\nexec: ./missing-binary\nui: webview\n"
	if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}

	k := startKernel(t, cfg)
	got := k.Registry().Snapshot()
	if len(got) != 1 || got[0].ID != "alpha" {
		t.Fatalf("roster = %+v, want the dropped-in plugin", got)
	}
}

// buildShutdownPlugin compiles the testdata fixture plugin into dir. It is
// explicitly path-built (not part of ./...) because it lives under
// testdata/, which the Go toolchain never treats as an ordinary package.
func buildShutdownPlugin(t *testing.T, outDir string) {
	t.Helper()
	cmd := exec.Command("go", "build", "-o", filepath.Join(outDir, "shutdownplugin"), "./testdata/shutdownplugin")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("build shutdownplugin fixture: %v\n%s", err, out)
	}
}

// This is the Finding-1 regression test: BroadcastShutdown only enqueues
// into a non-blocking outbox, and Supervisor.Stop follows immediately with
// SIGTERM. A direct signal beats a gRPC round trip over a unix socket
// essentially always, so without a drain wait between the two, a plugin's
// OnShutdown hook — exactly where the SDK and its worked examples tell
// authors to flush buffered state — loses that race on every core restart.
//
// The fixture plugin (testdata/shutdownplugin) writes its marker file ONLY
// from inside OnShutdown, so the marker's existence after Stop is direct
// evidence the Shutdown message won the race, not a side effect of some
// other write path. Reverting shutdownDrainGrace's wait in
// Host.BroadcastShutdown (rpc.go) back to a bare enqueue-and-return
// reproduces the failure reliably.
func TestShutdownMessageIsDeliveredBeforeSIGTERM(t *testing.T) {
	cfg := testConfig(t)
	dir := filepath.Join(cfg.PluginsDir, "shutdownplug")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	buildShutdownPlugin(t, dir)
	manifest := "id: shutdownplug\nname: ShutdownPlug\nexec: ./shutdownplugin\nui: none\n"
	if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}

	k, err := New(cfg, zap.NewNop())
	if err != nil {
		t.Fatal(err)
	}
	if err := k.Start(context.Background()); err != nil {
		t.Fatal(err)
	}

	// Wait for the plugin to actually register before shutting down —
	// otherwise this could pass trivially because there was nothing to
	// signal yet.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if got, _ := k.Registry().State("shutdownplug"); got == StateUp {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if got, _ := k.Registry().State("shutdownplug"); got != StateUp {
		t.Fatalf("fixture plugin never reached up (state = %v); can't test shutdown ordering", got)
	}

	k.Stop(context.Background())

	markerPath := filepath.Join(cfg.DataRoot, "shutdownplug", "shutdown-received")
	if _, err := os.Stat(markerPath); err != nil {
		t.Fatalf("shutdown marker not found at %s after Stop: %v — the plugin's OnShutdown hook lost the race against SIGTERM", markerPath, err)
	}
}

func TestStopIsIdempotent(t *testing.T) {
	cfg := testConfig(t)
	k := startKernel(t, cfg)
	k.Stop(context.Background())
	k.Stop(context.Background()) // must not panic or hang

	if _, err := os.Stat(cfg.SocketPath); !os.IsNotExist(err) {
		t.Fatal("socket file should be removed on Stop")
	}
}

// main.go can reach this state directly: kernel.New succeeds but Start is
// never reached (or never called at all) before shutdown, and main.go
// calls Stop unconditionally on any non-nil *Kernel. Stop must not panic,
// hang, or require Start to have run first.
func TestStopWithoutStartIsSafe(t *testing.T) {
	cfg := testConfig(t)
	k, err := New(cfg, zap.NewNop())
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})
	go func() {
		k.Stop(context.Background())
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Stop hung when Start was never called")
	}

	// Nothing was ever bound, so there is nothing to have left behind.
	if _, err := os.Stat(cfg.SocketPath); !os.IsNotExist(err) {
		t.Fatal("no socket file should exist; Start never ran")
	}

	// A second Stop, and a late Start, must both remain safe.
	k.Stop(context.Background())
	if err := k.Start(context.Background()); err == nil {
		t.Fatal("Start after Stop should refuse rather than bind listeners no one will ever clean up")
	}
}

// A plugins directory that does not exist is the default state of a fresh
// install. Core must create it rather than silently scanning nothing —
// "drop a directory in" is not an instruction you can follow if the
// directory you would drop it into is absent.
func TestStartCreatesThePluginsDir(t *testing.T) {
	cfg := testConfig(t)
	if _, err := os.Stat(cfg.PluginsDir); !os.IsNotExist(err) {
		t.Fatalf("precondition: dir should not exist yet, got %v", err)
	}

	startKernel(t, cfg)

	fi, err := os.Stat(cfg.PluginsDir)
	if err != nil {
		t.Fatalf("Start did not create the plugins dir: %v", err)
	}
	if !fi.IsDir() {
		t.Fatal("plugins path exists but is not a directory")
	}
}

// Creating it must never disturb one that is already populated.
func TestStartLeavesAnExistingPluginsDirAlone(t *testing.T) {
	cfg := testConfig(t)
	dir := filepath.Join(cfg.PluginsDir, "alpha")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := "id: alpha\nname: Alpha\nexec: ./missing-binary\nui: webview\n"
	if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}

	k := startKernel(t, cfg)

	if got := k.Registry().Snapshot(); len(got) != 1 || got[0].ID != "alpha" {
		t.Fatalf("roster = %+v, want the pre-existing plugin still discovered", got)
	}
}

// A packaged build ships its first-party plugins read-only inside the .app
// bundle, so Start must roster plugins it will never be able to write to —
// and must not create that directory, which for a signed bundle would be a
// silent lie about what shipped.
func TestStartDiscoversBundledPluginsDir(t *testing.T) {
	cfg := testConfig(t)
	cfg.BundledPluginsDir = filepath.Join(t.TempDir(), "plugins")
	dir := filepath.Join(cfg.BundledPluginsDir, "shipped")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := "id: shipped\nname: Shipped\nexec: ./missing-binary\nui: webview\n"
	if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}

	k := startKernel(t, cfg)

	if got := k.Registry().Snapshot(); len(got) != 1 || got[0].ID != "shipped" {
		t.Fatalf("roster = %+v, want the bundled plugin discovered", got)
	}
}

// The precedence rule, end to end: an installed copy in the writable dir
// supersedes the one that shipped. Backwards, an update would be dead on
// arrival and the symptom — "my new version isn't running" — points at
// everything except discovery.
func TestStartPrefersInstalledOverBundled(t *testing.T) {
	cfg := testConfig(t)
	cfg.BundledPluginsDir = filepath.Join(t.TempDir(), "plugins")

	for _, p := range []struct{ root, name string }{
		{cfg.PluginsDir, "Installed"},
		{cfg.BundledPluginsDir, "Shipped"},
	} {
		dir := filepath.Join(p.root, "widget")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		manifest := "id: widget\nname: " + p.name + "\nexec: ./missing-binary\nui: webview\n"
		if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	k := startKernel(t, cfg)

	got := k.Registry().Snapshot()
	if len(got) != 1 || got[0].Name != "Installed" {
		t.Fatalf("roster = %+v, want only the installed copy", got)
	}
}

// BundledPluginsDir is read-only by contract. Start creates PluginsDir
// because "drop a directory in and restart" needs somewhere to drop into;
// creating a missing bundled dir instead papers over a broken bundle.
func TestStartNeverCreatesTheBundledPluginsDir(t *testing.T) {
	cfg := testConfig(t)
	cfg.BundledPluginsDir = filepath.Join(t.TempDir(), "nonexistent")

	startKernel(t, cfg)

	if _, err := os.Stat(cfg.BundledPluginsDir); !os.IsNotExist(err) {
		t.Fatalf("bundled dir must be left alone, stat err = %v", err)
	}
}
