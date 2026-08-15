// Package vibecheck holds no Go source of its own — the plugin is written in
// Swift. What lives here is the harness that drives the built Swift binary
// against a REAL kernel (and, in sdk_wire_test.go, against a scripted core),
// because everything this task claims is a claim about two processes talking
// to each other and cannot be observed from inside either one.
package vibecheck

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"context"

	"github.com/vibecare-io/vibecare/backend/kernel"
	"go.uber.org/zap"
)

// resourceBundle is the directory SwiftPM emits next to the executable for
// `resources: [.copy("ui")]`. The generated Bundle.module accessor resolves
// it as Bundle.main.bundleURL/<name>, i.e. as a sibling of the binary — so
// installing the binary without it leaves the plugin with no UI to serve.
// Both this harness and `just build-vibecheck-plugin` therefore copy it.
const resourceBundle = "vibecheck_vibecheck.bundle"

var (
	buildOnce sync.Once
	builtDir  string // absolute path of .build/release
	buildErr  error
)

// buildVibeCheckOnce compiles the Swift plugin exactly once per test binary.
// The -sectcreate flags embed Info.plist so macOS has an
// NSCameraUsageDescription to show; without them a bare binary gets no
// camera prompt at all. They are carried here (rather than left to the
// Justfile) so the artifact under test is the same Mach-O shape that ships.
func buildVibeCheckOnce(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		cmd := exec.Command("swift", "build", "-c", "release",
			"-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
			"-Xlinker", "__info_plist", "-Xlinker", "Info.plist")
		cmd.Dir = "."
		if out, err := cmd.CombinedOutput(); err != nil {
			buildErr = err
			t.Logf("swift build failed:\n%s", out)
			return
		}
		builtDir, buildErr = filepath.Abs(filepath.Join(".build", "release"))
	})
	if buildErr != nil {
		t.Fatalf("swift build: %v", buildErr)
	}
	return builtDir
}

// installVibeCheck lays out a plugin directory the way core expects to find
// one: the binary, its resource bundle, and the manifest, all siblings.
func installVibeCheck(t *testing.T, dir string) {
	t.Helper()
	release := buildVibeCheckOnce(t)

	copyFile(t, filepath.Join(release, "vibecheck"), filepath.Join(dir, "vibecheck"), 0o755)
	copyTree(t, filepath.Join(release, resourceBundle), filepath.Join(dir, resourceBundle))

	manifest, err := os.ReadFile("manifest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}
}

func copyFile(t *testing.T, src, dst string, mode os.FileMode) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		t.Fatalf("write %s: %v", dst, err)
	}
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
	if err != nil {
		t.Fatalf("copy %s -> %s: %v", src, dst, err)
	}
}

// shortSocketDir works around macOS capping sockaddr_un.sun_path at 104
// bytes: t.TempDir() is a long, deeply nested path under $TMPDIR that
// routinely blows past it (see backend/kernel/kernel_test.go).
func shortSocketDir(t *testing.T, prefix string) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", prefix)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// liveKernel drops the built plugin into a temp plugins dir, starts a real
// in-process kernel over it, and returns an authenticated HTTP client, the
// origin, home (the root DataRoot was derived from, so callers can assert
// on-disk state directly), and the kernel itself.
func liveKernel(t *testing.T) (*http.Client, string, string, *kernel.Kernel) {
	t.Helper()
	home := t.TempDir()
	pluginDir := filepath.Join(home, "plugins", "vibecheck")
	if err := os.MkdirAll(pluginDir, 0o755); err != nil {
		t.Fatal(err)
	}
	installVibeCheck(t, pluginDir)

	cfg := kernel.Config{
		PluginsDir:  filepath.Join(home, "plugins"),
		DataRoot:    filepath.Join(home, "data"),
		SocketPath:  filepath.Join(shortSocketDir(t, "vcvibe"), "core.sock"),
		SessionPath: filepath.Join(home, "session"),
	}
	k, err := kernel.New(cfg, zap.NewNop())
	if err != nil {
		t.Fatal(err)
	}
	if err := k.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { k.Stop(context.Background()) })

	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: sessionJar{token: k.Token(), inner: jar}}
	base := k.BaseURL(context.Background())

	// swift build is slow on a cold cache, and buildVibeCheckOnce runs
	// inside this helper.
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := client.Get(base + "/p/vibecheck/api/state")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return client, base, home, k
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("plugin never became reachable through the proxy")
	return nil, "", "", nil
}

// sessionJar always presents the session cookie, which is what the Swift
// shell's webview does after the ?vc= handoff.
type sessionJar struct {
	token string
	inner http.CookieJar
}

func (j sessionJar) SetCookies(u *url.URL, c []*http.Cookie) { j.inner.SetCookies(u, c) }
func (j sessionJar) Cookies(u *url.URL) []*http.Cookie {
	return []*http.Cookie{{Name: "vc_session", Value: j.token}}
}

// The whole loop: drop the directory in, start core, and there is a working
// Swift plugin behind the proxy.
func TestPluginServesUIAndAPIThroughTheProxy(t *testing.T) {
	client, base, _, _ := liveKernel(t)

	resp, err := client.Get(base + "/p/vibecheck/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("code = %d body = %.200s", resp.StatusCode, body)
	}
	// Assert on content, not just the status: uiIndexHTML() resolves the
	// SwiftPM resource bundle at runtime, and a 200 alone would still pass
	// if that lookup silently failed and something generic came back.
	if !bytes.Contains(body, []byte("<title>VibeCheck</title>")) {
		t.Fatalf("body is not the packaged ui/index.html: %.200s", body)
	}
}

// The dashboard is the debugging surface for everything else, so it has to
// show a real running plugin correctly.
func TestDashboardShowsThePluginUp(t *testing.T) {
	client, base, _, _ := liveKernel(t)

	resp, err := client.Get(base + "/_core/api/plugins")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var payload rosterPayload
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	for _, p := range payload.Plugins {
		if p.ID != "vibecheck" {
			continue
		}
		if p.State != "up" {
			t.Fatalf("state = %q, want up", p.State)
		}
		if p.PID == 0 {
			t.Fatal("pid is 0; the plugin is not actually running")
		}
		return
	}
	t.Fatal("vibecheck not in the roster")
}

type rosterPayload struct {
	Plugins []struct {
		ID    string `json:"id"`
		State string `json:"state"`
		PID   int    `json:"pid"`
	} `json:"plugins"`
}

// Requests that skip the token must not reach the plugin — plugins write no
// auth code, so this is the only thing standing in front of them.
func TestProxyRejectsUnauthenticatedRequests(t *testing.T) {
	_, base, _, _ := liveKernel(t)

	resp, err := http.Get(base + "/p/vibecheck/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", resp.StatusCode)
	}
}

// Required assertion 1: the plugin must be GONE on SIGTERM well inside
// supervisor.go's 5 s shutdownGrace, not SIGKILLed at the end of it.
//
// This is the test that keeps main.swift's `await host.waitForShutdown()`
// honored. VCHost's SIGTERM handler deliberately does not call exit(), so
// termination happens only because waitForShutdown() returns and main falls
// off the end. Swap that final await back for a sleep-forever and every
// other test in this package still passes while every real shutdown costs a
// SIGKILL — this one fails.
func TestSIGTERMExitsWellInsideCoreShutdownGrace(t *testing.T) {
	client, base, _, _ := liveKernel(t)

	resp, err := client.Get(base + "/_core/api/plugins")
	if err != nil {
		t.Fatal(err)
	}
	var payload rosterPayload
	err = json.NewDecoder(resp.Body).Decode(&payload)
	resp.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	pid := 0
	for _, p := range payload.Plugins {
		if p.ID == "vibecheck" {
			pid = p.PID
		}
	}
	if pid == 0 {
		t.Fatalf("no running pid for vibecheck in %+v", payload.Plugins)
	}

	// Exactly the signal supervisor.terminate sends, to exactly the same
	// process. The kernel is the parent and reaps it, so ESRCH from
	// signal 0 is the observable "it is gone".
	sent := time.Now()
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		t.Fatalf("SIGTERM %d: %v", pid, err)
	}
	const grace = 5 * time.Second // supervisor.go's shutdownGrace
	deadline := sent.Add(grace)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, syscall.Signal(0)); err != nil {
			took := time.Since(sent)
			t.Logf("plugin exited %v after SIGTERM (grace is %v)", took, grace)
			// "Well inside" is the claim, not merely "inside": a plugin
			// that only just beats the SIGKILL has no margin left for a
			// slower machine or a real flush hook.
			if took > grace/2 {
				t.Fatalf("took %v to exit; that is not well inside the %v grace", took, grace)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("plugin still alive %v after SIGTERM; core would have SIGKILLed it", grace)
}

// Required assertion 5. ConfigStore does not exist yet; the rest of the test
// is written so Task 10 only has to delete the Skip.
//
// A GET would only prove in-memory state, which is true even of a store
// whose flush is a silent no-op. The claim this test exists to make is the
// wiring: core's DataRoot -> VIBECARE_DATA_DIR -> the file on disk.
func TestConfigPersistsToTheDataDir(t *testing.T) {
	client, base, home, _ := liveKernel(t)
	body := `{"enabled":true,"sensitivity":0.7,"dwell":0.15,"cooldown":5,"enabledBehaviors":["nailBiting"]}`
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}

	onDisk, err := os.ReadFile(filepath.Join(home, "data", "vibecheck", "config.json"))
	if err != nil {
		t.Fatalf("config.json not on disk: %v", err)
	}
	var saved struct {
		Sensitivity float64 `json:"sensitivity"`
	}
	if err := json.Unmarshal(onDisk, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.Sensitivity != 0.7 {
		t.Fatalf("sensitivity on disk = %v, want 0.7", saved.Sensitivity)
	}
}

// Task 15's error discipline, copied from plugins/todo/main.go's own
// comments: a caller's mistake — malformed JSON — gets a 400, never a 500
// (which would suggest the plugin's own fault) and never a 200 (which
// would silently accept garbage).
func TestConfigRejectsMalformedJSON(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader("{not json"))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

// PUT stores whatever VibeCheckConfig.clamped() produces, not the raw
// decode — this asserts that clamping is genuinely applied end to end
// (through the real HTTP round trip, not just ConfigStore.save's own unit
// tests) before the value is echoed back by a later GET.
func TestConfigClampsOutOfRangeValues(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	body := `{"enabled":false,"sensitivity":5.0,"dwell":0.15,"cooldown":900,"enabledBehaviors":[]}`
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("PUT got %d, want 200", resp.StatusCode)
	}

	getResp, err := client.Get(base + "/p/vibecheck/api/config")
	if err != nil {
		t.Fatal(err)
	}
	defer getResp.Body.Close()
	var c struct {
		Sensitivity float64 `json:"sensitivity"`
		Cooldown    float64 `json:"cooldown"`
	}
	if err := json.NewDecoder(getResp.Body).Decode(&c); err != nil {
		t.Fatal(err)
	}
	if c.Sensitivity != 1.0 {
		t.Fatalf("sensitivity = %v, want clamped to 1.0", c.Sensitivity)
	}
	if c.Cooldown != 30 {
		t.Fatalf("cooldown = %v, want clamped to 30", c.Cooldown)
	}
}

// `permission` must always be reported — even before the camera has ever
// been asked to start — so the UI (or a future TUI client) can explain
// itself ("off by choice" vs. "asked and refused") without a special case
// for "never asked yet".
func TestStateReportsPermissionAndConfig(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	resp, err := client.Get(base + "/p/vibecheck/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s struct {
		Running    bool   `json:"running"`
		Permission string `json:"permission"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	if s.Permission == "" {
		t.Fatal("permission must always be reported so the UI can explain itself")
	}
}

// GET and POST are both accepted for the two alert-action targets (ruling
// P4): a client following an action URL issues a GET, and core's proxy
// does not rewrite methods. `enabled:false` is used throughout so nothing
// here touches the real camera.
func TestConfigDisableAcceptsGetAndPost(t *testing.T) {
	for _, method := range []string{"GET", "POST"} {
		t.Run(method, func(t *testing.T) {
			client, base, _, _ := liveKernel(t)
			req, err := http.NewRequest(method, base+"/p/vibecheck/api/config/disable", nil)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != 200 {
				body, _ := io.ReadAll(resp.Body)
				t.Fatalf("%s got %d, want 200: %.200s", method, resp.StatusCode, body)
			}
			var c struct {
				Enabled bool `json:"enabled"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&c); err != nil {
				t.Fatal(err)
			}
			if c.Enabled {
				t.Fatal("enabled = true, want false after /api/config/disable")
			}
		})
	}
}

func TestSnoozeAcceptsGetAndPost(t *testing.T) {
	for _, method := range []string{"GET", "POST"} {
		t.Run(method, func(t *testing.T) {
			client, base, _, _ := liveKernel(t)
			req, err := http.NewRequest(method, base+"/p/vibecheck/api/snooze?minutes=10", nil)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != 200 {
				body, _ := io.ReadAll(resp.Body)
				t.Fatalf("%s got %d, want 200: %.200s", method, resp.StatusCode, body)
			}
		})
	}
}

func TestSnoozeWithoutMinutesIs400(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	resp, err := client.Get(base + "/p/vibecheck/api/snooze")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

// The bundled behavior icons: the plugin's own `NotificationPreferences.
// default(for:)` points every default alert at "icons/<id>.svg", so these
// must actually resolve through the real resource bundle, not just through
// the in-process Swift unit tests (which inject a fake loadIcon closure).
func TestIconRouteServesTheBundledIcons(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	for _, id := range []string{"nail-biting", "nose-picking", "hair-pulling"} {
		resp, err := client.Get(base + "/p/vibecheck/icons/" + id + ".svg")
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("icon %q: got %d, want 200: %.200s", id, resp.StatusCode, body)
		}
		if ct := resp.Header.Get("Content-Type"); ct != "image/svg+xml" {
			t.Fatalf("icon %q: Content-Type = %q, want image/svg+xml", id, ct)
		}
		if !bytes.Contains(body, []byte("<svg")) {
			t.Fatalf("icon %q: body does not look like an SVG: %.100s", id, body)
		}
	}

	resp, err := client.Get(base + "/p/vibecheck/icons/not-a-real-icon.svg")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("unknown icon: got %d, want 404", resp.StatusCode)
	}
}

// Required assertion for Task 14 (PreviewStream/JPEGEncoder): the proxy
// must genuinely STREAM /preview.mjpeg, not buffer it until the response
// completes — which for this endpoint never happens at all, since the
// multipart response is intentionally never-ending. A single boundary
// marker would pass even if proxy.go's `FlushInterval: -1` were deleted
// and the whole thing only flushed once at close; at least two markers,
// observed while the read loop below has NOT yet seen EOF, is the only
// assertion that actually tells "streaming" apart from
// "buffered-then-sent-once". See proxy.go's own comment for why
// FlushInterval: -1 is there at all.
//
// Route wiring note: `/preview.mjpeg` itself is registered by Task 15's
// main.swift (this plugin's route table, per the plan, lists it as
// "Task 14" only in the sense that PreviewStream — the type this test's
// sibling Swift suite exercises directly — is what Task 14 delivers).
// Task 15 wires the route (`registerVibeCheckRoutes` -> `preview.attach`),
// so the t.Skip that gated this on Task 15 landing is gone.
//
// Deviation from the brief's literal Step 5 claim ("Task 15 deletes the
// t.Skip line...the assertion body needs no further changes"): the camera
// is gated on `config.enabled` alone, deliberately and repeatedly
// documented that way throughout DetectionEngine.swift/CameraSession.swift
// ("a fresh install with detection off must never trigger the TCC
// camera-permission prompt") — a URL fetch must not be what turns the
// camera on behind a user's back. `PreviewStream.publish` is only ever
// called from `DetectionEngine.didOutput`, which the camera never invokes
// unless `apply(enabled: true)` has run. So a PUT enabling detection is
// added here as test SETUP (not a weakening of the assertion that follows,
// which is unchanged): without it, `liveKernel`'s freshly-booted plugin
// (default config: `enabled: false`) attaches a writer to an idle
// `PreviewStream` that never receives a single frame, and the test fails
// with 0 boundary markers for a reason that has nothing to do with
// streaming — confirmed by first running this test unmodified against the
// real Task 15 wiring and observing exactly that failure.
func TestPreviewStreamsThroughTheProxy(t *testing.T) {
	client, base, _, _ := liveKernel(t)

	putBody := `{"enabled":true,"sensitivity":0.5,"dwell":0.15,"cooldown":5,"enabledBehaviors":["nailBiting","nosePicking","hairPulling"]}`
	putReq, err := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(putBody))
	if err != nil {
		t.Fatal(err)
	}
	putReq.Header.Set("Content-Type", "application/json")
	putResp, err := client.Do(putReq)
	if err != nil {
		t.Fatal(err)
	}
	putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK {
		t.Fatalf("enabling detection: got %d, want 200", putResp.StatusCode)
	}

	req, err := http.NewRequest("GET", base+"/p/vibecheck/preview.mjpeg", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("code = %d body = %.200s", resp.StatusCode, body)
	}
	ct := resp.Header.Get("Content-Type")
	if !strings.Contains(ct, "multipart/x-mixed-replace") || !strings.Contains(ct, "boundary=vcframe") {
		t.Fatalf("Content-Type = %q, want multipart/x-mixed-replace with boundary=vcframe", ct)
	}

	// Read continuously in the background so the main loop below can poll
	// what has arrived so far without itself blocking on Read — the
	// response is 5s+ from ever hitting EOF if streaming is actually
	// working, so a single blocking Read is not an option here.
	//
	// `eofSeen` is the fix that makes "still open" a real assertion rather
	// than an unchecked comment: a buffered-then-closed response delivers
	// everything in one shot, so a version of this loop that only checked
	// `count >= 2` would pass for exactly the failure mode this test
	// exists to exclude — the read goroutine would already be past EOF by
	// the time the main loop's first 50ms poll observed the two markers.
	// Requiring `count >= 2 && !eofSeen` closes that: the two markers must
	// have been observed BEFORE the body ended, not merely before the
	// deadline.
	var mu sync.Mutex
	var received bytes.Buffer
	eofSeen := false
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				mu.Lock()
				received.Write(buf[:n])
				mu.Unlock()
			}
			if err != nil {
				mu.Lock()
				eofSeen = true
				mu.Unlock()
				return
			}
		}
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		count := bytes.Count(received.Bytes(), []byte("--vcframe"))
		ended := eofSeen
		body := received.String()
		mu.Unlock()

		if count >= 2 && !ended {
			return // PASS: two-plus frames arrived, and the body was not yet closed.
		}
		if ended {
			t.Fatalf("response body ended before two boundary markers arrived while still open (count=%d): %.300s", count, body)
		}
		time.Sleep(50 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	t.Fatalf("only %d boundary markers arrived within 5s (want >= 2, still open); got %.300s",
		bytes.Count(received.Bytes(), []byte("--vcframe")), received.String())
}
