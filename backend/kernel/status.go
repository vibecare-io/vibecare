package kernel

import (
	"encoding/json"
	"html/template"
	"net/http"
	"strings"
)

// corePrefix is reserved for core itself and is NEVER proxied. Plugin ids
// cannot collide with it: the id regex rejects a leading underscore.
//
// Every route below is composed from this constant rather than repeating
// the literal, so changing it can't silently unmount half the dashboard.
const corePrefix = "/_core/"

const (
	statusPath      = corePrefix + "status"
	apiPluginsPath  = corePrefix + "api/plugins"
	apiPluginsIndex = apiPluginsPath + "/" // + "<id>/restart"
)

// Restarter is the slice of the supervisor the dashboard needs. Depending
// on the interface rather than the concrete type keeps status.go testable
// without spawning processes.
type Restarter interface {
	Restart(id string) error
}

type statusPluginJSON struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Path            string `json:"path"`
	UI              string `json:"ui"`
	State           string `json:"state"`
	Detail          string `json:"detail"`
	PID             int    `json:"pid"`
	UptimeSec       int64  `json:"uptime_sec"`
	Restarts        int    `json:"restarts"`
	ProbeLatencyMS  int64  `json:"probe_latency_ms"`
	EventsPublished uint64 `json:"events_published"`
	EventsDelivered uint64 `json:"events_delivered"`
	LastEventUnix   int64  `json:"last_event_unix"`
}

// HasUI reports whether the dashboard should link to this plugin's own
// path. A `ui: none` plugin serves no HTML there — same as the shell,
// which excludes it from the roster — so linking to it would only ever
// produce a dead or meaningless click. Exported so html/template's
// reflection-based method lookup (used by the {{.HasUI}} call below) can
// see it — an unexported method is invisible to that, even from within
// this same package.
func (s statusPluginJSON) HasUI() bool { return s.UI != "none" }

type statusJSON struct {
	Plugins []statusPluginJSON `json:"plugins"`
}

func toStatusJSON(stats []PluginStat) statusJSON {
	out := statusJSON{Plugins: make([]statusPluginJSON, 0, len(stats))}
	for _, s := range stats {
		out.Plugins = append(out.Plugins, statusPluginJSON{
			ID:              s.ID,
			Name:            s.Name,
			Path:            s.Path,
			UI:              s.UI,
			State:           s.State.String(),
			Detail:          s.Detail,
			PID:             s.PID,
			UptimeSec:       s.UptimeSec,
			Restarts:        s.Restarts,
			ProbeLatencyMS:  s.ProbeLatencyMS,
			EventsPublished: s.EventsPublished,
			EventsDelivered: s.EventsDelivered,
			LastEventUnix:   s.LastEventUnix,
		})
	}
	return out
}

// dashboardTmpl is deliberately one self-contained page with no assets and
// no JavaScript: it must render when everything else is broken, which is
// the only time anyone looks at it.
var dashboardTmpl = template.Must(template.New("status").Parse(`<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>VibeCare — plugin status</title>
<style>
 body{font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;padding:2rem;max-width:64rem;margin:auto}
 table{border-collapse:collapse;width:100%}
 th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #ddd;vertical-align:top}
 th{font-weight:600;color:#666;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
 code{font:12px ui-monospace,Menlo,monospace}
 .s-up{color:#118a3d}.s-degraded{color:#b26a00}.s-down,.s-failed{color:#b3261e}.s-starting{color:#666}
 button{font:inherit;padding:.2rem .6rem}
 @media (prefers-color-scheme:dark){
   body{background:#1b1b1b;color:#eee}th,td{border-color:#333}th{color:#999}
 }
</style>
<h1>Plugin status</h1>
<table>
<tr><th>Plugin</th><th>State</th><th>PID</th><th>Uptime</th><th>Restarts</th>
    <th>Probe</th><th>Events pub/del</th><th>Detail</th><th></th></tr>
{{range .Plugins}}
<tr>
  <td>{{if .HasUI}}<a href="` + proxyPrefix + `{{.ID}}/">{{.Name}}</a>{{else}}{{.Name}}{{end}}<br><code>{{.ID}}</code></td>
  <td class="s-{{.State}}">{{.State}}</td>
  <td>{{if .PID}}{{.PID}}{{else}}—{{end}}</td>
  <td>{{if .UptimeSec}}{{.UptimeSec}}s{{else}}—{{end}}</td>
  <td>{{.Restarts}}</td>
  <td>{{if .ProbeLatencyMS}}{{.ProbeLatencyMS}}ms{{else}}—{{end}}</td>
  <td>{{.EventsPublished}} / {{.EventsDelivered}}</td>
  <td>{{.Detail}}</td>
  <td><form method="post" action="` + apiPluginsIndex + `{{.ID}}/restart">
      <button type="submit">Restart</button></form></td>
</tr>
{{else}}
<tr><td colspan="9">No plugins discovered.</td></tr>
{{end}}
</table>
<p><a href="` + apiPluginsPath + `">JSON</a> · refreshes every 5s</p>
`))

// NewStatusHandler serves core's own surface. It follows the same HTML/JSON
// split core asks of plugins (§7.2): /_core/status renders, and
// /_core/api/plugins returns the identical data for anything that isn't a
// browser.
func NewStatusHandler(reg *Registry, r Restarter) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc(statusPath, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = dashboardTmpl.Execute(w, toStatusJSON(reg.Snapshot()))
	})

	mux.HandleFunc(apiPluginsPath, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(toStatusJSON(reg.Snapshot()))
	})

	// <apiPluginsIndex><id>/restart
	mux.HandleFunc(apiPluginsIndex, func(w http.ResponseWriter, req *http.Request) {
		rest := strings.TrimPrefix(req.URL.Path, apiPluginsIndex)
		id, action, ok := strings.Cut(rest, "/")
		if !ok || action != "restart" {
			http.NotFound(w, req)
			return
		}
		if _, known := reg.Manifest(id); !known {
			http.NotFound(w, req)
			return
		}
		// Restart mutates state, so it is POST-only: a prefetch or an
		// <img src> must not be able to bounce a plugin.
		if req.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if err := r.Restart(id); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		http.Redirect(w, req, statusPath, http.StatusSeeOther)
	})

	return mux
}
