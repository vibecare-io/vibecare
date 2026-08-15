package kernel

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.uber.org/zap"
)

type fakeRestarter struct {
	called []string
	err    error
}

func (f *fakeRestarter) Restart(id string) error {
	f.called = append(f.called, id)
	return f.err
}

func statusFixture(t *testing.T) (*Registry, *fakeRestarter, http.Handler) {
	t.Helper()
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: "Alpha", Icon: "circle", Exec: "./a", UI: "webview"})
	reg.Add(Manifest{ID: "beta", Name: "Beta", Icon: "square", Exec: "./b", UI: "none"})
	reg.SetPort("alpha", 41000)
	reg.SetProcess("alpha", 4242)
	reg.SetState("alpha", StateUp, "")
	reg.CountPublished("alpha")
	reg.CountDelivered("alpha", 7)
	reg.SetState("beta", StateFailed, "5 consecutive failed starts; last: exit status 3")

	fr := &fakeRestarter{}
	return reg, fr, NewStatusHandler(reg, fr, nil)
}

func TestStatusJSONShape(t *testing.T) {
	_, _, h := statusFixture(t)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/api/plugins", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
		t.Fatalf("content-type = %q", ct)
	}

	var got statusJSON
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal: %v\nbody: %s", err, rec.Body.String())
	}
	if len(got.Plugins) != 2 {
		t.Fatalf("got %d plugins, want 2", len(got.Plugins))
	}

	a := got.Plugins[0]
	if a.ID != "alpha" || a.Name != "Alpha" || a.Path != "/p/alpha/" || a.State != "up" {
		t.Errorf("alpha = %+v", a)
	}
	if a.PID != 4242 || a.EventsPublished != 1 || a.EventsDelivered != 7 {
		t.Errorf("alpha stats = %+v", a)
	}

	b := got.Plugins[1]
	if b.State != "failed" || !strings.Contains(b.Detail, "exit status 3") {
		t.Errorf("beta = %+v; detail must carry the exit reason", b)
	}
}

// The dashboard is how a failed plugin becomes visible and recoverable
// without reading logs or restarting core.
func TestStatusHTMLListsEveryPluginWithItsState(t *testing.T) {
	_, _, h := statusFixture(t)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/status", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Fatalf("content-type = %q", ct)
	}

	body := rec.Body.String()
	for _, want := range []string{"Alpha", "Beta", "up", "failed", "exit status 3", "4242", "/_core/api/plugins/alpha/restart"} {
		if !strings.Contains(body, want) {
			t.Errorf("dashboard missing %q", want)
		}
	}
}

// A `ui: none` plugin serves no HTML at its proxied path — the shell
// correctly excludes it from anything clickable, and the dashboard must do
// the same rather than linking to a page that doesn't exist.
func TestStatusHTMLDoesNotLinkPluginsWithNoUI(t *testing.T) {
	_, _, h := statusFixture(t)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/status", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}

	body := rec.Body.String()
	if !strings.Contains(body, "Beta") {
		t.Fatalf("dashboard must still name the ui:none plugin:\n%s", body)
	}
	if strings.Contains(body, `href="/p/beta/"`) {
		t.Errorf("dashboard links to /p/beta/, but beta declares ui: none and serves nothing there:\n%s", body)
	}
	// The webview-capable plugin must still be linked.
	if !strings.Contains(body, `href="/p/alpha/"`) {
		t.Errorf("dashboard did not link the ui:webview plugin:\n%s", body)
	}
}

func TestRestartEndpointCallsSupervisor(t *testing.T) {
	_, fr, h := statusFixture(t)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/_core/api/plugins/beta/restart", nil))

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("code = %d, want 303 back to the dashboard", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/_core/status" {
		t.Errorf("Location = %q", loc)
	}
	if len(fr.called) != 1 || fr.called[0] != "beta" {
		t.Fatalf("Restart called with %v, want [beta]", fr.called)
	}
}

func TestRestartUnknownPluginIs404(t *testing.T) {
	_, _, h := statusFixture(t)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/_core/api/plugins/ghost/restart", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rec.Code)
	}
}

// Restart mutates state; a GET must not be able to trigger it (a prefetch
// or an <img> tag would be enough).
func TestRestartRejectsGET(t *testing.T) {
	_, fr, h := statusFixture(t)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/api/plugins/beta/restart", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("code = %d, want 405", rec.Code)
	}
	if len(fr.called) != 0 {
		t.Fatal("GET triggered a restart")
	}
}

func TestUnknownCorePathIs404(t *testing.T) {
	_, _, h := statusFixture(t)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rec.Code)
	}
}

func TestStatusHTMLEscapesPluginSuppliedStrings(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	reg.Add(Manifest{ID: "alpha", Name: `<script>alert(1)</script>`, Icon: "circle", Exec: "./a", UI: "webview"})
	reg.SetState("alpha", StateDown, `<script>alert(2)</script>`)

	fr := &fakeRestarter{}
	h := NewStatusHandler(reg, fr, nil)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/status", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}

	body := rec.Body.String()
	if strings.Contains(body, "<script>") {
		t.Fatalf("dashboard rendered an unescaped <script> tag:\n%s", body)
	}
	if !strings.Contains(body, "&lt;script&gt;") {
		t.Errorf("dashboard did not escape plugin-supplied name/detail:\n%s", body)
	}
}
