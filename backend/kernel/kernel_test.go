package kernel

import (
	"context"
	"net/http"
	"os"
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
