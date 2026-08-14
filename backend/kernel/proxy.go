package kernel

import (
	"fmt"
	"html"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"

	"go.uber.org/zap"
)

// proxyPrefix is the mount point for every plugin's HTTP surface.
const proxyPrefix = "/p/"

// NewProxy returns the handler for /p/<plugin-id>/*. It rewrites
//
//	http://127.0.0.1:<core>/p/<id>/<path>  ->  http://127.0.0.1:<plugin>/<path>
//
// and is the reason plugins write no authentication code: by the time a
// request gets here it has already passed Auth.Middleware.
func NewProxy(reg *Registry, log *zap.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rest := strings.TrimPrefix(r.URL.Path, proxyPrefix)
		id, path, hasSlash := strings.Cut(rest, "/")

		if id == "" {
			http.NotFound(w, r)
			return
		}
		if !hasSlash {
			// Relative asset URLs inside the plugin's HTML resolve against
			// the trailing slash, so normalize rather than guess.
			http.Redirect(w, r, proxyPrefix+id+"/", http.StatusMovedPermanently)
			return
		}

		stat, ok := lookupStat(reg, id)
		if !ok {
			http.NotFound(w, r)
			return
		}
		port, hasPort := reg.Port(id)
		if !hasPort || (stat.State != StateUp && stat.State != StateDegraded) {
			servePluginDown(w, stat)
			return
		}

		target, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
		if err != nil {
			servePluginDown(w, stat)
			return
		}

		tracked := &startedResponseWriter{ResponseWriter: w}

		rp := &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.SetURL(target)
				pr.Out.URL.Path = "/" + path
				pr.Out.Host = target.Host
			},
			// MANDATORY. Modern Go already auto-flushes text/event-stream
			// responses and any response with an unknown (chunked)
			// Content-Length — see (*ReverseProxy).flushInterval in the
			// standard library, which forces immediate flushing for both
			// regardless of this field. This setting is what's left: a
			// streaming response with a known Content-Length and a
			// non-SSE content type (e.g. a single MJPEG frame written in
			// two chunks). It is also cheap insurance against that stdlib
			// heuristic changing out from under us. There is a test for
			// this; do not remove it.
			FlushInterval: -1,
			ErrorHandler: func(_ http.ResponseWriter, _ *http.Request, err error) {
				log.Warn("proxy error", zap.String("plugin", id), zap.Error(err))
				handleProxyError(tracked, stat)
			},
		}
		rp.ServeHTTP(tracked, r)
	})
}

// handleProxyError is ReverseProxy's ErrorHandler, factored out so the
// decision it makes can be exercised directly in tests rather than only
// through httputil.ReverseProxy's internal call graph.
//
// ErrorHandler is documented to run both when the backend never responded
// at all (tracked.started == false — nothing has reached the client yet,
// so a down page is the right response) and, in principle, after a
// response has already begun. The two need different handling: a down
// page is only safe to splice in for the first case. Attempting it for
// the second would append error markup to a half-sent body and log a
// "superfluous WriteHeader" warning — truncating the connection is the
// correct outcome for a plugin that dies mid-stream, not a corrupted page.
//
// In practice, on the standard library's current ReverseProxy, a body-copy
// failure after headers were sent panics with http.ErrAbortHandler inside
// ReverseProxy itself rather than calling ErrorHandler — the net/http
// server recovers that panic and truncates the connection cleanly without
// ever reaching this function at all. This check earns its keep as
// insurance against that internal routing changing, not against something
// observed failing today.
func handleProxyError(tracked *startedResponseWriter, stat PluginStat) {
	if tracked.started {
		return
	}
	servePluginDown(tracked, stat)
}

// startedResponseWriter wraps an http.ResponseWriter and records whether a
// real response has begun, so NewProxy's ErrorHandler can tell "the backend
// never responded" (safe to serve an error page) apart from "the backend
// died after it had already started replying" (not safe — the error page
// would be appended to whatever was already sent).
//
// 1xx informational responses (e.g. Early Hints) do not count: Go's own
// http.ResponseWriter treats them as non-final and happily accepts a real
// WriteHeader afterwards, so this tracker must match that or it would
// silently swallow a legitimate error page behind a discarded 1xx.
//
// Implementing Unwrap lets http.ResponseController (used internally by
// ReverseProxy for flushing and protocol upgrades) see through this
// wrapper to the real ResponseWriter's Flusher/Hijacker, so streaming and
// upgrades keep working exactly as if this wrapper weren't there.
type startedResponseWriter struct {
	http.ResponseWriter
	started bool
}

func (w *startedResponseWriter) WriteHeader(code int) {
	if code < 100 || code >= 200 {
		w.started = true
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *startedResponseWriter) Write(b []byte) (int, error) {
	w.started = true
	return w.ResponseWriter.Write(b)
}

func (w *startedResponseWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func lookupStat(reg *Registry, id string) (PluginStat, bool) {
	for _, s := range reg.Snapshot() {
		if s.ID == id {
			return s, true
		}
	}
	return PluginStat{}, false
}

// servePluginDown is the generic error page shown in place of a plugin
// that isn't serving. v1 has no render-while-down: the client retries the
// view when the roster reports the plugin back up.
func servePluginDown(w http.ResponseWriter, stat PluginStat) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusServiceUnavailable)
	detail := stat.Detail
	if detail == "" {
		detail = "no further detail"
	}
	fmt.Fprintf(w, `<!doctype html><meta charset="utf-8">
<title>%s is not running</title>
<body style="font:14px/1.5 -apple-system,sans-serif;padding:2rem">
<h1>%s is not running</h1>
<p>State: <code>%s</code></p>
<p>%s</p>
<p>This page reloads automatically when the plugin comes back.</p>`,
		html.EscapeString(stat.Name),
		html.EscapeString(stat.Name),
		html.EscapeString(stat.State.String()),
		html.EscapeString(detail))
}
