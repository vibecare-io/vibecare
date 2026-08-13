package kernel

import (
	"sort"
	"sync"
	"time"

	"go.uber.org/zap"
)

// State is a plugin's lifecycle state. degraded is deliberately a visible
// state rather than an internal one: it is where the tab still loads but
// misbehaves, and hiding it would make that indistinguishable from slow.
type State int

const (
	StateStarting State = iota
	StateUp
	StateDegraded
	StateDown
	StateFailed
)

func (s State) String() string {
	switch s {
	case StateStarting:
		return "starting"
	case StateUp:
		return "up"
	case StateDegraded:
		return "degraded"
	case StateDown:
		return "down"
	case StateFailed:
		return "failed"
	}
	return "unknown"
}

// PluginStat is a point-in-time, copy-by-value view of one plugin. It is
// what the roster stream and the status dashboard both render, so it holds
// everything either needs and nothing either would have to ask for.
type PluginStat struct {
	ID     string
	Name   string
	Icon   string
	Path   string
	UI     string
	State  State
	Detail string

	PID             int
	UptimeSec       int64
	Restarts        int
	ProbeLatencyMS  int64
	EventsPublished uint64
	EventsDelivered uint64
	LastEventUnix   int64
}

// plugin is the registry's mutable per-plugin record. Every field is
// guarded by Registry.mu.
type plugin struct {
	manifest Manifest
	state    State
	detail   string
	port     uint32
	pid      int
	since    time.Time // when the current state was entered
	restarts int
	probeMS  int64

	published uint64
	delivered uint64
	lastEvent time.Time
}

type watcher struct {
	ch     chan []PluginStat
	closed bool
}

// Registry is the kernel's plugin table and the single source of the
// roster. Core sits on both the plugin stream and the proxy, so every stat
// here is observed by core itself — no plugin cooperation required.
type Registry struct {
	log *zap.Logger

	mu       sync.Mutex
	plugins  map[string]*plugin
	order    []string // sorted ids, maintained on Add
	watchers map[*watcher]struct{}
}

func NewRegistry(log *zap.Logger) *Registry {
	return &Registry{
		log:      log,
		plugins:  map[string]*plugin{},
		watchers: map[*watcher]struct{}{},
	}
}

// Add registers a discovered manifest. New plugins start in StateStarting:
// they have been discovered but have not yet completed the Register
// handshake.
func (r *Registry) Add(m Manifest) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.plugins[m.ID]; exists {
		return
	}
	r.plugins[m.ID] = &plugin{manifest: m, state: StateStarting, since: time.Now()}
	r.order = append(r.order, m.ID)
	sort.Strings(r.order)
}

func (r *Registry) Manifests() []Manifest {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Manifest, 0, len(r.order))
	for _, id := range r.order {
		out = append(out, r.plugins[id].manifest)
	}
	return out
}

func (r *Registry) Manifest(id string) (Manifest, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.plugins[id]
	if !ok {
		return Manifest{}, false
	}
	return p.manifest, true
}

// SetState transitions a plugin and fans the whole roster out to watchers.
// A no-op transition (same state, same detail) stays quiet — otherwise
// every successful 10s health probe would re-push the roster to every
// connected client.
func (r *Registry) SetState(id string, s State, detail string) {
	r.mu.Lock()
	p, ok := r.plugins[id]
	if !ok {
		r.mu.Unlock()
		return
	}
	if p.state == s && p.detail == detail {
		r.mu.Unlock()
		return
	}
	if p.state != s {
		p.since = time.Now()
	}
	p.state, p.detail = s, detail
	snap := r.snapshotLocked()
	r.notifyLocked(snap)
	r.mu.Unlock()

	r.log.Info("plugin state", zap.String("plugin", id), zap.String("state", s.String()), zap.String("detail", detail))
}

func (r *Registry) State(id string) (State, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.plugins[id]
	if !ok {
		return StateStarting, false
	}
	return p.state, true
}

func (r *Registry) SetPort(id string, port uint32) { r.mutate(id, func(p *plugin) { p.port = port }) }

func (r *Registry) Port(id string) (uint32, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.plugins[id]
	if !ok || p.port == 0 {
		return 0, false
	}
	return p.port, true
}

func (r *Registry) SetProcess(id string, pid int) { r.mutate(id, func(p *plugin) { p.pid = pid }) }
func (r *Registry) IncRestarts(id string)         { r.mutate(id, func(p *plugin) { p.restarts++ }) }

func (r *Registry) SetProbeLatency(id string, d time.Duration) {
	r.mutate(id, func(p *plugin) { p.probeMS = d.Milliseconds() })
}

func (r *Registry) CountPublished(id string) {
	r.mutate(id, func(p *plugin) { p.published++; p.lastEvent = time.Now() })
}

func (r *Registry) CountDelivered(id string, n int) {
	r.mutate(id, func(p *plugin) { p.delivered += uint64(n) })
}

// mutate applies fn under the lock. Stat mutations deliberately do NOT
// notify watchers: counters change constantly and the roster is a
// state-change stream, not a metrics feed. The dashboard polls Snapshot
// instead.
func (r *Registry) mutate(id string, fn func(*plugin)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if p, ok := r.plugins[id]; ok {
		fn(p)
	}
}

func (r *Registry) Snapshot() []PluginStat {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snapshotLocked()
}

func (r *Registry) snapshotLocked() []PluginStat {
	out := make([]PluginStat, 0, len(r.order))
	for _, id := range r.order {
		p := r.plugins[id]
		st := PluginStat{
			ID:              p.manifest.ID,
			Name:            p.manifest.Name,
			Icon:            p.manifest.Icon,
			UI:              p.manifest.UI,
			Path:            "/p/" + p.manifest.ID + "/",
			State:           p.state,
			Detail:          p.detail,
			PID:             p.pid,
			Restarts:        p.restarts,
			ProbeLatencyMS:  p.probeMS,
			EventsPublished: p.published,
			EventsDelivered: p.delivered,
		}
		if p.state == StateUp || p.state == StateDegraded {
			st.UptimeSec = int64(time.Since(p.since).Seconds())
		}
		if !p.lastEvent.IsZero() {
			st.LastEventUnix = p.lastEvent.Unix()
		}
		out = append(out, st)
	}
	return out
}

// Watch returns a channel that receives the current roster immediately and
// a fresh full roster on every state change. The roster is small and
// changes rarely, so there is no need for deltas.
func (r *Registry) Watch() (<-chan []PluginStat, func()) {
	w := &watcher{ch: make(chan []PluginStat, 1)}

	r.mu.Lock()
	r.watchers[w] = struct{}{}
	w.ch <- r.snapshotLocked()
	r.mu.Unlock()

	var once sync.Once
	cancel := func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			delete(r.watchers, w)
			w.closed = true
			close(w.ch)
		})
	}
	return w.ch, cancel
}

// notifyLocked pushes snap to every watcher without ever blocking. A full
// buffer means the watcher hasn't drained the previous roster yet; that
// stale roster is discarded in favour of this newer one, because a client
// only ever cares about the current state of the world.
func (r *Registry) notifyLocked(snap []PluginStat) {
	for w := range r.watchers {
		if w.closed {
			continue
		}
		select {
		case w.ch <- snap:
		default:
			select {
			case <-w.ch:
			default:
			}
			select {
			case w.ch <- snap:
			default:
			}
		}
	}
}
