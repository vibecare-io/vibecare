//go:build dev

package main

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeUI creates a throwaway ui-like directory and returns its path.
func writeUI(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// A fingerprint has to change when content changes and hold steady when it
// doesn't — otherwise the watcher either misses edits or reloads forever.
func TestFingerprintTracksContentChanges(t *testing.T) {
	dir := writeUI(t, map[string]string{"index.html": "<h1>one</h1>"})

	first := uiFingerprint(dir)
	if first == "" {
		t.Fatal("fingerprint of a non-empty dir should not be empty")
	}
	if again := uiFingerprint(dir); again != first {
		t.Fatalf("fingerprint changed with no edit: %q -> %q", first, again)
	}

	// Same length, different bytes: a size-only fingerprint would miss this.
	time.Sleep(10 * time.Millisecond)
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<h1>two</h1>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed := uiFingerprint(dir); changed == first {
		t.Fatal("fingerprint did not change after an edit of equal length")
	}
}

func TestFingerprintSeesNewAndRemovedFiles(t *testing.T) {
	dir := writeUI(t, map[string]string{"index.html": "<h1>hi</h1>"})
	base := uiFingerprint(dir)

	added := filepath.Join(dir, "extra.css")
	if err := os.WriteFile(added, []byte("body{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	withExtra := uiFingerprint(dir)
	if withExtra == base {
		t.Fatal("adding a file did not change the fingerprint")
	}

	if err := os.Remove(added); err != nil {
		t.Fatal(err)
	}
	if uiFingerprint(dir) != base {
		t.Fatal("removing the added file should restore the original fingerprint")
	}
}

func TestInjectReloadScript(t *testing.T) {
	withBody := []byte("<html><body><h1>hi</h1></body></html>")
	got := string(injectReloadScript(withBody))
	if !strings.Contains(got, "EventSource") {
		t.Fatalf("script not injected: %s", got)
	}
	if strings.Index(got, "EventSource") > strings.Index(got, "</body>") {
		t.Fatal("script must be injected BEFORE </body>")
	}

	// Our own index.html has no </body>; the script must still land.
	noBody := []byte("<h1>hi</h1>")
	if !strings.Contains(string(injectReloadScript(noBody)), "EventSource") {
		t.Fatal("script not appended when </body> is absent")
	}
}

// The reload endpoint is relative so it resolves through core's proxy at
// /p/<id>/_dev/reload and inherits the session cookie.
func TestInjectedURLIsRelative(t *testing.T) {
	got := string(injectReloadScript([]byte("<h1>hi</h1>")))
	if strings.Contains(got, "http://") || strings.Contains(got, "'/_dev") {
		t.Fatalf("injected URL must be relative, got: %s", got)
	}
	if !strings.Contains(got, "_dev/reload") {
		t.Fatalf("injected URL missing: %s", got)
	}
}

func TestUIHandlerInjectsIntoHTMLOnly(t *testing.T) {
	css := "body { color: red }"
	dir := writeUI(t, map[string]string{
		"index.html": "<html><body>hi</body></html>",
		"style.css":  css,
	})
	h := uiHandlerDir(dir)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if !strings.Contains(rec.Body.String(), "EventSource") {
		t.Fatalf("index.html was not augmented: %s", rec.Body.String())
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/style.css", nil))
	if rec.Body.String() != css {
		t.Fatalf("non-HTML must pass through byte-identical, got %q", rec.Body.String())
	}
}

// The whole point of dev mode: edits land without a rebuild.
func TestUIHandlerServesFromDiskNotEmbed(t *testing.T) {
	dir := writeUI(t, map[string]string{"index.html": "<html><body>before</body></html>"})
	h := uiHandlerDir(dir)

	if err := os.WriteFile(filepath.Join(dir, "index.html"),
		[]byte("<html><body>after</body></html>"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if !strings.Contains(rec.Body.String(), "after") {
		t.Fatalf("handler served stale content: %s", rec.Body.String())
	}
}

func TestHubBroadcastReachesSubscribers(t *testing.T) {
	hub := newReloadHub()
	ch, cancel := hub.subscribe()
	defer cancel()

	hub.broadcast()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatal("subscriber never received the broadcast")
	}
}

// A browser tab that closed must not wedge the broadcaster.
func TestHubDoesNotBlockOnAnIdleSubscriber(t *testing.T) {
	hub := newReloadHub()
	_, cancel := hub.subscribe()
	defer cancel()

	done := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			hub.broadcast()
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("broadcast blocked on a subscriber that never reads")
	}
}

func TestUnsubscribeStopsDelivery(t *testing.T) {
	hub := newReloadHub()
	ch, cancel := hub.subscribe()
	cancel()
	cancel() // idempotent

	hub.broadcast()
	if _, open := <-ch; open {
		t.Fatal("channel should be closed after cancel")
	}
}

func TestWatchBroadcastsOnChange(t *testing.T) {
	dir := writeUI(t, map[string]string{"index.html": "<h1>one</h1>"})
	hub := newReloadHub()
	ch, cancel := hub.subscribe()
	defer cancel()

	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	go hub.watch(ctx, dir, 20*time.Millisecond)

	time.Sleep(50 * time.Millisecond) // let it take a baseline
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<h1>two</h1>"), 0o644); err != nil {
		t.Fatal(err)
	}

	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("watcher did not report the edit")
	}
}

func TestWatchStaysQuietWithoutChanges(t *testing.T) {
	dir := writeUI(t, map[string]string{"index.html": "<h1>one</h1>"})
	hub := newReloadHub()
	ch, cancel := hub.subscribe()
	defer cancel()

	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	go hub.watch(ctx, dir, 20*time.Millisecond)

	select {
	case <-ch:
		t.Fatal("watcher fired with no edit — the page would reload forever")
	case <-time.After(300 * time.Millisecond):
	}
}

// text/event-stream is exactly the content type Go's ReverseProxy
// auto-flushes, which is what lets this work through core's proxy.
func TestSSEStreamsReloadEvents(t *testing.T) {
	hub := newReloadHub()
	srv := httptest.NewServer(http.HandlerFunc(hub.serveSSE))
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("content-type = %q", ct)
	}

	read := make(chan string, 1)
	go func() {
		r := bufio.NewReader(resp.Body)
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			if strings.HasPrefix(line, "data:") {
				read <- strings.TrimSpace(line)
				return
			}
		}
	}()

	time.Sleep(100 * time.Millisecond) // let the subscriber attach
	hub.broadcast()

	select {
	case line := <-read:
		if !strings.Contains(line, "reload") {
			t.Fatalf("event = %q", line)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no SSE event arrived")
	}
}
