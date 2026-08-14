package kernel

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
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
// buffers the response and a streaming preview never arrives until the
// handler returns — i.e. never. This runs against a real listener because
// httptest.Recorder cannot observe flushing.
//
// The response shape here is deliberate and load-bearing: Go's stdlib
// ReverseProxy (net/http/httputil, (*ReverseProxy).flushInterval) already
// forces immediate flushing on its own, regardless of FlushInterval,
// whenever the response is Content-Type: text/event-stream OR has an
// unknown (chunked) Content-Length. Using either of those shapes here
// would make this test pass whether or not the proxy code actually sets
// FlushInterval — it would be checking what the stdlib already does on its
// own, not what this proxy's own configuration contributes.
// image/jpeg with an explicit, fully-known Content-Length is the one
// streaming shape the stdlib does NOT auto-flush; it is the shape that
// still depends on FlushInterval being set explicitly. Do not "simplify"
// this back to text/event-stream or drop the Content-Length — either
// change would silently disarm the guard while it kept passing.
func TestProxyStreamsWithoutBuffering(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	release := make(chan struct{})
	var releaseOnce sync.Once
	doRelease := func() { releaseOnce.Do(func() { close(release) }) }

	first := []byte("FIRST-HALF")
	second := []byte("SECOND-HALF")
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Content-Length", strconv.Itoa(len(first)+len(second)))
		w.WriteHeader(http.StatusOK)
		w.Write(first)
		w.(http.Flusher).Flush()
		<-release // hold the handler open; the first half must already be out
		w.Write(second)
	}))

	front := httptest.NewServer(NewProxy(reg, zap.NewNop()))
	defer front.Close()
	// Safety net: whatever branch below runs, the backend handler must
	// eventually unblock or front.Close() above hangs waiting on an
	// outstanding request forever — release is a plain channel receive,
	// unrelated to the TCP connection, so nothing else can wake it up.
	defer doRelease()

	// The request runs in its own goroutine because, with a small known
	// Content-Length and no flushing, even the response HEADERS never
	// reach the client until the handler returns — i.e. until the backend
	// is released. A synchronous http.Get here would deadlock against the
	// very release this test needs to trigger on timeout: the goroutine
	// lets the 2-second budget below apply to the whole exchange, not
	// just the body.
	type result struct {
		buf []byte
		err error
	}
	got := make(chan result, 1)
	go func() {
		resp, err := http.Get(front.URL + "/p/alpha/frame.jpg")
		if err != nil {
			got <- result{err: err}
			return
		}
		defer resp.Body.Close()
		buf := make([]byte, len(first))
		_, err = io.ReadFull(resp.Body, buf)
		got <- result{buf: buf, err: err}
	}()

	select {
	case r := <-got:
		if r.err != nil {
			t.Fatalf("read error: %v", r.err)
		}
		if string(r.buf) != string(first) {
			t.Fatalf("read %q, want %q", r.buf, first)
		}
	case <-time.After(2 * time.Second):
		doRelease() // let the backend finish so front.Close() doesn't also hang
		t.Fatal("first half never arrived within 2s — the proxy is buffering; FlushInterval must be -1")
	}
}

// A response has already reached the client (headers, at minimum a
// non-1xx status) when the backend it is being proxied from disappears.
// ReverseProxy's ErrorHandler is documented to run for this case as well
// as for "the backend never responded at all" — and the two must not be
// handled the same way, or a plugin that dies mid-stream gets a "not
// running" error page spliced into whatever it had already sent, plus a
// superfluous-WriteHeader log line.
//
// httputil.ReverseProxy does not, in practice, reach ErrorHandler for a
// plain body-copy failure on the current standard library — it panics
// with http.ErrAbortHandler internally instead, and net/http's server
// recovers that panic by truncating the connection cleanly on its own.
// This test exercises exactly that real, live path end to end and
// confirms the client-visible outcome is what it should be — clean
// truncation, nothing appended — without asserting anything about
// whether ErrorHandler itself ran. TestHandleProxyErrorSkipsStartedResponse
// below is what actually proves the ErrorHandler guard: it calls the
// same handleProxyError function NewProxy wires in, with a response that
// has already started, and would fail if the started check were removed.
func TestProxyDeadMidStreamTruncatesCleanly(t *testing.T) {
	reg := NewRegistry(zap.NewNop())
	upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "partial-body")
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler) // simulate the plugin dying mid-response
	}))

	front := httptest.NewServer(NewProxy(reg, zap.NewNop()))
	defer front.Close()

	resp, err := http.Get(front.URL + "/p/alpha/stream")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (the real status the plugin already sent)", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.HasPrefix(string(body), "partial-body") {
		t.Fatalf("body = %q, want it to start with the bytes the plugin already sent", body)
	}
	if strings.Contains(string(body), "is not running") || strings.Contains(string(body), "<!doctype") {
		t.Fatalf("body = %q, an error page was spliced into a response that had already started", body)
	}
}

// The direct, deterministic proof for the ErrorHandler guard: call the
// exact function NewProxy wires into ErrorHandler, once with a response
// that has already sent real content and once with a fresh one, and check
// each gets the outcome only it should. Delete the `if tracked.started`
// check in handleProxyError and the first case fails — the down page gets
// appended to "already-sent".
func TestHandleProxyErrorSkipsStartedResponse(t *testing.T) {
	rec := httptest.NewRecorder()
	tracked := &startedResponseWriter{ResponseWriter: rec}
	tracked.WriteHeader(http.StatusOK)
	tracked.Write([]byte("already-sent"))

	handleProxyError(tracked, PluginStat{ID: "alpha", Name: "alpha", State: StateUp})

	if got := rec.Body.String(); got != "already-sent" {
		t.Fatalf("body = %q, want it untouched by an error page once the response had started", got)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want the original 200 to stand", rec.Code)
	}
}

func TestHandleProxyErrorServesDownPageWhenNothingSentYet(t *testing.T) {
	rec := httptest.NewRecorder()
	tracked := &startedResponseWriter{ResponseWriter: rec}

	handleProxyError(tracked, PluginStat{ID: "alpha", Name: "alpha", State: StateDown, Detail: "exit status 1"})

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("code = %d, want 503", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "alpha") {
		t.Fatalf("body = %q, want the down page", rec.Body.String())
	}
}

// A 1xx informational response (e.g. Early Hints) must not count as
// "started": Go's own http.ResponseWriter treats 1xx as non-final and
// accepts a real WriteHeader afterwards, so if a plugin sends a 1xx and
// then dies before completing its real response, the down page must
// still be served — not silently swallowed because a naive tracker
// thought the response had already begun.
func TestStartedResponseWriterIgnoresInformationalHeaders(t *testing.T) {
	rec := httptest.NewRecorder()
	tracked := &startedResponseWriter{ResponseWriter: rec}
	tracked.WriteHeader(http.StatusEarlyHints) // 103
	if tracked.started {
		t.Fatal("a 1xx response must not mark the response as started")
	}
	tracked.WriteHeader(http.StatusOK)
	if !tracked.started {
		t.Fatal("a real (non-1xx) WriteHeader must mark the response as started")
	}
}
