//go:build dev

package main

// Dev build: the UI is served from disk and the browser reloads itself when
// a file under ui/ changes. Build with `go build -tags dev` (or `just dev`).
//
// The shipping counterpart is ui_embed.go, which bakes ui/ into the binary
// and makes devReload a no-op. Both export uiHandler and devReload so
// main.go never branches on the mode, and nothing in this file reaches a
// release binary.

import (
	"bytes"
	"context"
	"fmt"
	"hash/fnv"
	"io/fs"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	uiDir = "ui"
	// reloadPath is relative to the plugin's own root, so through core's
	// proxy it resolves to /p/<id>/_dev/reload and inherits the session
	// cookie — the plugin needs no auth code of its own.
	reloadPath   = "/_dev/reload"
	pollInterval = 300 * time.Millisecond
)

// reloadScript is injected into every HTML response in dev builds. The
// EventSource URL is deliberately relative; an absolute one would break the
// moment the plugin is mounted somewhere other than the root.
const reloadScript = `<script>new EventSource('_dev/reload').onmessage=()=>location.reload()</script>`

// uiHandler serves ui/ from disk so an edit is visible on refresh.
func uiHandler() http.Handler { return uiHandlerDir(uiDir) }

func uiHandlerDir(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Without this the browser serves its own cache back to itself and
		// the reload looks broken.
		w.Header().Set("Cache-Control", "no-store")
		inj := &htmlInjector{ResponseWriter: w, buf: &bytes.Buffer{}}
		files.ServeHTTP(inj, r)
		inj.finish()
	})
}

// htmlInjector buffers HTML responses so the reload script can be spliced in
// and Content-Length corrected. Everything else streams straight through
// untouched — a rewritten stylesheet or image would be a bug, not a feature.
type htmlInjector struct {
	http.ResponseWriter
	buf     *bytes.Buffer
	status  int
	isHTML  bool
	started bool
}

func (i *htmlInjector) WriteHeader(code int) {
	if i.started {
		return
	}
	i.started = true
	i.status = code
	i.isHTML = code == http.StatusOK &&
		strings.Contains(i.Header().Get("Content-Type"), "text/html")
	if !i.isHTML {
		i.ResponseWriter.WriteHeader(code)
	}
}

func (i *htmlInjector) Write(b []byte) (int, error) {
	if !i.started {
		i.WriteHeader(http.StatusOK)
	}
	if i.isHTML {
		return i.buf.Write(b)
	}
	return i.ResponseWriter.Write(b)
}

// finish emits a buffered HTML response. It is a no-op for anything that was
// already written straight through.
func (i *htmlInjector) finish() {
	if !i.isHTML {
		return
	}
	out := injectReloadScript(i.buf.Bytes())
	i.Header().Set("Content-Length", strconv.Itoa(len(out)))
	i.ResponseWriter.WriteHeader(i.status)
	_, _ = i.ResponseWriter.Write(out)
}

// injectReloadScript places the script just before </body>, or appends it
// when there is no body tag — our own index.html has none.
func injectReloadScript(page []byte) []byte {
	const marker = "</body>"
	if idx := bytes.LastIndex(page, []byte(marker)); idx >= 0 {
		out := make([]byte, 0, len(page)+len(reloadScript))
		out = append(out, page[:idx]...)
		out = append(out, reloadScript...)
		return append(out, page[idx:]...)
	}
	return append(append([]byte{}, page...), reloadScript...)
}

// uiFingerprint summarises every file under dir by path, size, and modtime.
// Content is deliberately not hashed: this runs on a timer and the point is
// to be cheap, not cryptographically exact.
func uiFingerprint(dir string) string {
	h := fnv.New64a()
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		fmt.Fprintf(h, "%s:%d:%d\n", path, info.Size(), info.ModTime().UnixNano())
		return nil
	})
	if err != nil {
		// A transient read error must not look like an edit, or the page
		// reloads in a loop. Report the previous state by returning nothing
		// and letting the caller keep its baseline.
		return ""
	}
	return strconv.FormatUint(h.Sum64(), 16)
}

// reloadHub fans "something changed" out to every connected browser tab.
type reloadHub struct {
	mu   sync.Mutex
	subs map[chan struct{}]struct{}
}

func newReloadHub() *reloadHub {
	return &reloadHub{subs: map[chan struct{}]struct{}{}}
}

func (h *reloadHub) subscribe() (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()

	var once sync.Once
	return ch, func() {
		once.Do(func() {
			h.mu.Lock()
			defer h.mu.Unlock()
			delete(h.subs, ch)
			close(ch)
		})
	}
}

// broadcast sends under the lock so a send can never race a close, and never
// blocks: a tab with a reload already pending does not need a second one.
func (h *reloadHub) broadcast() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// watch polls dir and broadcasts whenever the fingerprint moves. Polling
// beats a filesystem-notification dependency here: this is a handful of
// files, it only ever runs in dev builds, and it needs no third-party code.
func (h *reloadHub) watch(ctx context.Context, dir string, every time.Duration) {
	last := uiFingerprint(dir)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			cur := uiFingerprint(dir)
			if cur == "" || cur == last {
				continue
			}
			last = cur
			h.broadcast()
		}
	}
}

func (h *reloadHub) serveSSE(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	ch, cancel := h.subscribe()
	defer cancel()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case _, open := <-ch:
			if !open {
				return
			}
			fmt.Fprint(w, "data: reload\n\n")
			flusher.Flush()
		}
	}
}

// devReload starts the watcher and mounts the reload stream.
func devReload(mux *http.ServeMux) {
	hub := newReloadHub()
	go hub.watch(context.Background(), uiDir, pollInterval)
	mux.HandleFunc(reloadPath, hub.serveSSE)
	log.Printf("todo: dev build — serving %s/ from disk, live reload on %s", uiDir, reloadPath)
}
