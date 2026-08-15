// Package vc is the only package in this client that talks to VibeCare
// core. Both frontends — the cobra CLI and the bubbletea TUI — are thin
// layers over the types and calls defined here.
//
// The json tags in this file are a public contract. Agents and scripts
// consume `vibecare <cmd> --json` and depend on these field names, so
// renaming or removing one is a breaking change that requires bumping
// ContractVersion. Adding a field is always safe. See §5 of
// docs/superpowers/specs/2026-08-14-vibecare-cli-design.md.
package vc

import "time"

// ContractVersion is emitted as "v" on every --json payload. Bump it only
// when a field is renamed or removed.
const ContractVersion = 1

// State mirrors the kernel's plugin lifecycle states. It is a string rather
// than an enum so JSON consumers never see an integer whose meaning depends
// on a proto file they cannot read.
type State string

const (
	StateStarting State = "STARTING"
	StateUp       State = "UP"
	StateDegraded State = "DEGRADED"
	StateDown     State = "DOWN"
	StateFailed   State = "FAILED"
	// StateUnknown is what the client reports when core is unreachable and
	// it is showing a cached roster. The kernel never produces it.
	StateUnknown State = "UNKNOWN"
)

// Healthy reports whether this state means the plugin is serving. Used for
// the sidebar bullet and the status tally.
func (s State) Healthy() bool { return s == StateUp }

// Plugin is one row of the roster. Field names deliberately match the
// kernel's own /_core/api/plugins JSON so a reader that knows one knows the
// other.
//
// The stats fields (PID onward) are only populated when the kernel's HTTP
// surface was reachable; from the Shell stream alone they are zero. Stats
// reports which case applies.
type Plugin struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Icon   string `json:"icon,omitempty"`
	Path   string `json:"path"`
	UI     string `json:"ui,omitempty"`
	State  State  `json:"state"`
	Detail string `json:"detail,omitempty"`

	PID             int    `json:"pid"`
	UptimeSec       int64  `json:"uptime_sec"`
	Restarts        int    `json:"restarts"`
	ProbeLatencyMS  int64  `json:"probe_latency_ms"`
	EventsPublished uint64 `json:"events_published"`
	EventsDelivered uint64 `json:"events_delivered"`
	LastEventUnix   int64  `json:"last_event_unix"`
	LogPath         string `json:"log_path,omitempty"`

	// Dir is where the plugin's manifest lives and Build is the command it
	// declares for rebuilding itself. Both are empty for a plugin that
	// declares no build, which is how an installed plugin differs from one
	// being worked on. Adding fields is within the contract; see
	// ContractVersion.
	Dir   string `json:"dir,omitempty"`
	Build string `json:"build,omitempty"`

	// Stats is false when this row came from the Shell roster stream only,
	// meaning every numeric field above is a zero value rather than a
	// measurement. Consumers must not render "0 restarts" in that case.
	Stats bool `json:"stats"`
}

// HasUI reports whether the plugin serves anything at its proxied path. A
// `ui: none` plugin is headless and the Shell roster omits it entirely.
func (p Plugin) HasUI() bool { return p.UI != "none" && p.UI != "" }

// Roster is the full plugin list plus the kernel origin it was learned
// from. The origin is ephemeral (the kernel binds 127.0.0.1:0), so it is
// reported rather than configured.
type Roster struct {
	Plugins []Plugin `json:"plugins"`
	BaseURL string   `json:"base_url,omitempty"`
}

// Tally counts plugins by state. Cheap to compute and the single most
// useful line of `vibecare status`.
type Tally struct {
	Total    int `json:"total"`
	Up       int `json:"up"`
	Degraded int `json:"degraded"`
	Down     int `json:"down"`
	Failed   int `json:"failed"`
	Starting int `json:"starting"`
}

// Status is the whole-system snapshot behind `vibecare status`. Every
// section is independently nil-able because core can be partially up: gRPC
// answering while the kernel failed to start is a real, observed state.
type Status struct {
	Addr      string     `json:"addr"`
	Reachable bool       `json:"reachable"`
	Error     string     `json:"error,omitempty"`
	Version   string     `json:"version,omitempty"`
	Kernel    string     `json:"kernel_base_url,omitempty"`
	Scheduler *Scheduler `json:"scheduler,omitempty"`
	Plugins   Tally      `json:"plugins"`
}

// Scheduler is the subset of /api/scheduler/status worth showing. The
// endpoint returns more; this client renders what a human debugging it
// needs and keeps Raw for the rest.
type Scheduler struct {
	Running bool           `json:"running"`
	Raw     map[string]any `json:"raw,omitempty"`
}

// Schedule is one scheduled routine. Timestamps are RFC 3339 UTC on the
// wire; nil means the proto field was unset, which is distinct from zero.
type Schedule struct {
	ID            string     `json:"schedule_id"`
	ProfileID     string     `json:"profile_id,omitempty"`
	RoutineID     string     `json:"routine_id,omitempty"`
	Name          string     `json:"name"`
	RRule         string     `json:"rrule,omitempty"`
	Timezone      string     `json:"schedule_timezone,omitempty"`
	Notes         string     `json:"notes,omitempty"`
	Enabled       bool       `json:"enabled"`
	Type          string     `json:"schedule_type,omitempty"`
	DTStart       *time.Time `json:"dtstart,omitempty"`
	LastExecution *time.Time `json:"last_execution,omitempty"`
	NextExecution *time.Time `json:"next_execution,omitempty"`
	CreatedAt     *time.Time `json:"created_at,omitempty"`
	UpdatedAt     *time.Time `json:"updated_at,omitempty"`

	// Actions is populated only by Get, never by List — listing schedules
	// must not fan out into one GetScheduleActions call per row.
	Actions []Action `json:"actions,omitempty"`
}

// Routine is a named group of actions.
type Routine struct {
	ID        string     `json:"routine_id"`
	ProfileID string     `json:"profile_id,omitempty"`
	Name      string     `json:"name"`
	Notes     string     `json:"notes,omitempty"`
	Enabled   bool       `json:"enabled"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
	Actions   []Action   `json:"actions,omitempty"`
}

// Action is one unit of work a routine performs.
type Action struct {
	ID        string            `json:"action_id"`
	ProfileID string            `json:"profile_id,omitempty"`
	Name      string            `json:"name"`
	Type      string            `json:"action_type,omitempty"`
	Params    map[string]string `json:"parameters,omitempty"`
	Notes     string            `json:"notes,omitempty"`
	Enabled   bool              `json:"enabled"`
	Order     int32             `json:"order,omitempty"`
}

// ExecutionLog is one recorded routine run.
type ExecutionLog struct {
	LogID     int64             `json:"log_id"`
	RoutineID string            `json:"routine_id"`
	Timestamp *time.Time        `json:"timestamp,omitempty"`
	Completed bool              `json:"completed"`
	Notes     string            `json:"notes,omitempty"`
	Results   map[string]string `json:"action_results,omitempty"`
}

// Alert is one UI intent pushed by a plugin through Shell.Intents. Alerts
// are transient — core never retains them — so anything the client wants to
// keep, it keeps itself.
type Alert struct {
	Received time.Time     `json:"received"`
	Plugin   string        `json:"plugin"`
	Title    string        `json:"title"`
	Body     string        `json:"body,omitempty"`
	Level    string        `json:"level,omitempty"` // "info" | "warn"
	Actions  []AlertAction `json:"actions,omitempty"`
}

// Warn reports whether this alert should draw attention (bell, colour).
func (a Alert) Warn() bool { return a.Level == "warn" }

// AlertAction is a button the plugin asked the client to render. URL is
// plugin-relative: the full target is <base_url>/p/<plugin>/<url>.
type AlertAction struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}

// LogSource identifies one tailable stream of text. Path is authoritative;
// the client never reconstructs log paths from a convention, it reads them
// from the kernel's JSON (for plugins) or resolves the single known core
// path (for core itself).
type LogSource struct {
	// ID is "core" or a plugin id. It is the prefix shown in merged output.
	ID   string `json:"id"`
	Path string `json:"path"`
}

// LogLine is one line from one source, carrying enough context to be
// rendered in a merged view.
type LogLine struct {
	Source string `json:"source"`
	Text   string `json:"text"`
	// At is the client's receive time, not a parsed timestamp. Plugin output
	// is explicitly "diagnostic only; never parsed" (supervisor.go), so this
	// client does not attempt to parse a timestamp out of it.
	At time.Time `json:"at"`
}

// Event is one message published on core's bus, as an observer sees it.
//
// Plugin is who fired it — a subscriber knows why it was handed an event,
// but something watching everything has to be told. Payload is carried as a
// string because the bus is opaque bytes: core has no schema for it, and
// decoding here would be this client inventing meaning nobody gave it.
type Event struct {
	Plugin  string    `json:"plugin"`
	Topic   string    `json:"topic"`
	Payload string    `json:"payload,omitempty"`
	At      time.Time `json:"at"`
}

// Bytes is the payload size, which is what a stream view shows instead of a
// payload too long to fit on a line.
func (e Event) Bytes() int { return len(e.Payload) }

// Envelope wraps every --json payload so consumers can version-check
// without inspecting the shape. Exactly one of Data or Err is set.
type Envelope struct {
	V    int        `json:"v"`
	Data any        `json:"data,omitempty"`
	Err  *ErrorBody `json:"error,omitempty"`
}

// ErrorBody is the machine-readable form of a failure, carrying the same
// code the process exits with.
type ErrorBody struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}
