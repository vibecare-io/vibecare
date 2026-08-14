package kernel

import (
	"bufio"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"
)

// upPlugin registers a plugin in the registry backed by a live test server
// and marks it up.
func upPlugin(t *testing.T, reg *Registry, id string, h http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)

	u, _ := url.Parse(srv.URL)
	p, _ := strconv.Atoi(u.Port())

	reg.Add(Manifest{ID: id, Name: id, Exec: "./" + id, UI: "webview"})
	reg.SetPort(id, uint32(p))
	reg.SetState(id, StateUp, "")
	return srv
}

func TestProxyForwardsAndStripsPrefix(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "path=%s query=%s", r.URL.Path, r.URL.RawQuery)
	}))

	rec := httptest.NewRecorder()
	NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/api/tasks?done=1", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d", rec.Code)
	}
	if got := rec.Body.String(); got != "path=/api/tasks query=done=1" {
		t.Fatalf("plugin saw %q; the /p/<id> prefix must be stripped and the query preserved", got)
	}
}

// The root of a plugin is where its HTML lives; a bare /p/<id> must reach
// it rather than 404.
func TestProxyRootPath(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "path=%s", r.URL.Path)
	}))
	p := NewProxy(reg, zap.NewNop())

	rec := httptest.NewRecorder()
	p.ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))
	if got := rec.Body.String(); got != "path=/" {
		t.Fatalf("/p/alpha/ -> %q, want path=/", got)
	}

	// Without the trailing slash, redirect rather than guess — relative
	// asset URLs in the plugin's HTML depend on the trailing slash.
	rec = httptest.NewRecorder()
	p.ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha", nil))
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/p/alpha/" {
		t.Fatalf("code = %d location = %q, want 301 -> /p/alpha/", rec.Code, rec.Header().Get("Location"))
	}
}

func TestProxyPreservesMethodAndBody(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, r.ContentLength)
		r.Body.Read(b)
		fmt.Fprintf(w, "%s:%s", r.Method, b)
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/p/alpha/api/tasks", strings.NewReader("hello"))
	NewProxy(reg, zap.NewNop()).ServeHTTP(rec, req)

	if got := rec.Body.String(); got != "POST:hello" {
		t.Fatalf("plugin saw %q", got)
	}
}

// Plugin down -> a generic error page at its path, not a proxy attempt and
// not a raw connection error.
func TestProxyDownPluginServesErrorPage(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", okHandler)
	reg.SetState("alpha", StateDown, "exit status 1")

	rec := httptest.NewRecorder()
	NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("code = %d, want 503", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "alpha") || !strings.Contains(body, "exit status 1") {
		t.Fatalf("error page should name the plugin and its exit reason; got:\n%s", body)
	}
}

func TestProxyUnknownPluginIs404(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	rec := httptest.NewRecorder()
	NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/ghost/", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rec.Code)
	}
}

// A degraded plugin still serves — that is the whole distinction between
// degraded and down.
func TestProxyDegradedPluginStillProxies(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", okHandler)
	reg.SetState("alpha", StateDegraded, "slow")

	rec := httptest.NewRecorder()
	NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want the degraded plugin to still serve", rec.Code)
	}
}

// THE test that justifies FlushInterval = -1. Without it, ReverseProxy
// buffers the response and an MJPEG preview or SSE stream never arrives
// until the handler returns — i.e. never. This runs against a real
// listener because httptest.Recorder cannot observe flushing.
func TestProxyStreamsWithoutBuffering(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	release := make(chan struct{})
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		<-release // hold the handler open; the first chunk must already be out
		fmt.Fprint(w, "data: second\n\n")
	}))

	front := httptest.NewServer(NewProxy(reg, zap.NewNop()))
	defer front.Close()
	defer close(release)

	resp, err := http.Get(front.URL + "/p/alpha/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	type read struct {
		line string
		err  error
	}
	got := make(chan read, 1)
	go func() {
		line, err := bufio.NewReader(resp.Body).ReadString('\n')
		got <- read{line, err}
	}()

	select {
	case r := <-got:
		if r.err != nil || !strings.Contains(r.line, "first") {
			t.Fatalf("read %q, %v", r.line, r.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first chunk never arrived — the proxy is buffering; FlushInterval must be -1")
	}
}
