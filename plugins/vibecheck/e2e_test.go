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
//
// Plain `swift build`, with no -sectcreate: the vision cutover (design §8.1)
// moved every capture call out of this plugin, so there is no camera prompt
// for an embedded NSCameraUsageDescription to supply text for. The flags are
// mirrored from `just build-vibecheck-plugin` deliberately — the artifact
// under test must be the same Mach-O shape that ships — so if that recipe
// ever grows a link flag again, this must too.
func buildVibeCheckOnce(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		cmd := exec.Command("swift", "build", "-c", "release")
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
// one: the manifest at the root, and the binary wherever that manifest's
// `exec` says it lives, with the resource bundle beside it.
//
// The destination is DERIVED from the manifest via the kernel's own loader
// rather than hardcoded here. An earlier version of this helper hardcoded
// <dir>/vibecheck, which silently stopped matching the moment `exec` became
// ./dist/vibecheck (the flat-bundle fix — see `just build-vibecheck-plugin`):
// core spawned a path that did not exist, every liveKernel test burned its
// full 60s deadline, and the package blew Go's 10m timeout. Reading the same
// field core reads means this harness cannot drift from the manifest again.
//
// Returns the manifest-relative exec path so callers that spawn the binary
// directly (spawnPlugin) resolve it the same way, from the same read.
func installVibeCheck(t *testing.T, dir string) string {
	t.Helper()
	release := buildVibeCheckOnce(t)

	manifest, err := os.ReadFile("manifest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	installed := filepath.Join(dir, "manifest.yaml")
	if err := os.WriteFile(installed, manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := kernel.LoadManifest(installed)
	if err != nil {
		t.Fatal(err)
	}

	// m.Exec is relative to the plugin dir, which is what supervisor.go sets
	// cmd.Dir to. The bundle goes in the binary's OWN directory, not the
	// plugin root: Bundle.module resolves as a sibling of the executable.
	binary := filepath.Join(dir, filepath.FromSlash(m.Exec))
	if err := os.MkdirAll(filepath.Dir(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	copyFile(t, filepath.Join(release, "vibecheck"), binary, 0o755)
	copyTree(t, filepath.Join(release, resourceBundle), filepath.Join(filepath.Dir(binary), resourceBundle))
	return m.Exec
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
	//
	// `<title>VibeCheck</title>` alone cannot tell the real UI apart from
	// the Task 6 placeholder page it replaced — both carry that identical
	// title (a ninth can't-fail guard, caught when Task 16's implementer
	// tried to consume this contract). Two-sided instead: require a
	// structural marker unique to the real UI AND require the placeholder's
	// distinctive string to be absent — so neither a stale bundle nor some
	// future gutted page can slip through either half alone.
	//
	// The marker used to be `id="preview-off"`, the element the page toggled
	// when the live preview was off. The vision cutover deleted the preview
	// pane from this plugin entirely — the design's §7 puts the one preview
	// in vision's tab, because a detector cannot embed
	// `/p/vision/preview.mjpeg` without an absolute cross-plugin URL and the
	// plugin HTTP contract forbids those. `id="detection-status"` is the
	// equivalent structural marker on the page that replaced it: the row
	// carrying the on/off state, which is what this tab is now about.
	if !bytes.Contains(body, []byte(`id="detection-status"`)) {
		t.Fatalf("body is missing id=\"detection-status\" — not the real vibecheck UI: %.300s", body)
	}
	if bytes.Contains(body, []byte("arrives in Task")) {
		t.Fatalf("body still contains the Task 6 placeholder's text: %.300s", body)
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

// The state readout must always explain WHY nothing is being detected,
// even before anything has been detected — so the UI (or a future TUI
// client) can tell "off by choice" apart from "waiting on the provider"
// without a special case for "nothing has happened yet".
//
// This used to assert on `permission`. The vision cutover removed that
// field rather than leaving one that can only lie: this process no longer
// opens a capture session, so any camera-permission value it reported would
// be an invention. What replaced it is the bus-side equivalent —
// `vision.requiredTopics` (what this plugin has asked the provider to run)
// with `joined` (how many complete same-`seq` sets have actually arrived).
// `requiredTopics` non-empty with `joined == 0` is precisely the "asked and
// got nothing" case the old `permission` field existed to name.
func TestStateReportsVisionIntakeAndConfig(t *testing.T) {
	client, base, _, _ := liveKernel(t)
	resp, err := client.Get(base + "/p/vibecheck/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s struct {
		Running bool `json:"running"`
		Vision  *struct {
			RequiredTopics []string `json:"requiredTopics"`
			// A pointer so "absent" and "zero" are distinguishable: a
			// missing counter must fail this test, and `0` is the correct
			// and expected value on a freshly booted plugin that has
			// received no frames.
			Joined  *int `json:"joined"`
			Skipped *int `json:"skipped"`
		} `json:"vision"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	if s.Vision == nil {
		t.Fatal("state must report the vision intake so the UI can explain itself")
	}
	if s.Vision.RequiredTopics == nil {
		t.Fatal("requiredTopics must always be reported, even when empty")
	}
	if s.Vision.Joined == nil || s.Vision.Skipped == nil {
		t.Fatalf("joined/skipped must always be reported: %+v", s.Vision)
	}
}

// GET and POST are both accepted for the two alert-action targets (ruling
// P4): a client following an action URL issues a GET, and core's proxy
// does not rewrite methods. `enabled:false` is used throughout so nothing
// here touches the real camera.
// Seeds `enabled: true` before disabling — without this, `liveKernel`'s
// freshly-booted plugin already starts at the default `enabled: false`, and
// a handler that dropped `current.enabled = false` and merely echoed
// whatever was already there would pass just as easily as a correct one.
// (Review caught this: the assertion was decoration until this seed step
// was added.) The seeding PUT itself no longer blocks on the camera
// permission prompt — Task 15's follow-up fix responds before applying
// live, in a detached Task — so this stays fast even though `enabled:true`
// does end up starting the real camera in the background.
func TestConfigDisableAcceptsGetAndPost(t *testing.T) {
	for _, method := range []string{"GET", "POST"} {
		t.Run(method, func(t *testing.T) {
			client, base, _, _ := liveKernel(t)

			seedBody := `{"enabled":true,"sensitivity":0.5,"dwell":0.15,"cooldown":5,"enabledBehaviors":["nailBiting"]}`
			seedReq, err := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(seedBody))
			if err != nil {
				t.Fatal(err)
			}
			seedReq.Header.Set("Content-Type", "application/json")
			seedResp, err := client.Do(seedReq)
			if err != nil {
				t.Fatal(err)
			}
			seedResp.Body.Close()
			if seedResp.StatusCode != 200 {
				t.Fatalf("seeding enabled=true: got %d, want 200", seedResp.StatusCode)
			}

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

// `/preview.mjpeg` used to live here, and `TestPreviewStreamsThroughTheProxy`
// used to assert that core's proxy genuinely STREAMED it rather than
// buffering it until the response completed. Both are gone with the camera.
//
// The design's §7 gives this tree exactly one preview, in the vision plugin's
// tab: a detector cannot embed `/p/vision/preview.mjpeg` without an absolute
// cross-plugin URL, and the plugin HTTP contract forbids those because a
// plugin must not know where it is mounted. This plugin no longer registers
// the route, so the test could only have asserted a 404.
//
// The property it protected is NOT lost, and is in fact asserted more sharply
// where it belongs — `backend/kernel/proxy_test.go`'s
// `TestProxyStreamsWithoutBuffering`. That one drives the proxy directly with
// `image/jpeg` and a fully known `Content-Length`, which is the one streaming
// shape Go's `ReverseProxy` does NOT auto-flush and therefore the only shape
// that actually depends on `proxy.go` setting `FlushInterval: -1`. The test
// deleted here used a never-ending multipart body, which the stdlib flushes on
// its own regardless. Re-homing it into a vision e2e would additionally
// require a real camera and a TCC grant to produce a second frame.
