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

		rp := &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.SetURL(target)
				pr.Out.URL.Path = "/" + path
				pr.Out.Host = target.Host
			},
			// MANDATORY. Without this, ReverseProxy buffers responses and
			// MJPEG previews and SSE streams never reach the client. There
			// is a test for this; do not remove it.
			FlushInterval: -1,
			ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
				log.Warn("proxy error", zap.String("plugin", id), zap.Error(err))
				servePluginDown(w, stat)
			},
		}
		rp.ServeHTTP(w, r)
	})
}

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
