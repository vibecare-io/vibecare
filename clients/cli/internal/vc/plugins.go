package vc

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
)

// The kernel's own routes. They are composed from one constant for the same
// reason the kernel composes them from one constant: a typo here unmounts
// half the client.
const (
	kernelPluginsPath = "/_core/api/plugins"
	// sessionCookie is how the kernel's Auth accepts a token on a request it
	// did not originate (auth.go). The alternative, ?vc=<token>, is a
	// one-time handoff answered with a 302 that sets this very cookie — so
	// sending the cookie is the same credential without the round trip.
	sessionCookie = "vc_session"
)

// kernelPlugin mirrors the kernel's statusPluginJSON exactly. Field names are
// the kernel's, not this client's, so a reader who knows one knows the other
// — and so does vc.Plugin, which is why the copy below is field-for-field.
type kernelPlugin struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Path            string `json:"path"`
	UI              string `json:"ui"`
	LogPath         string `json:"log_path"`
	Dir             string `json:"dir"`
	Build           string `json:"build"`
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

type kernelStatus struct {
	Plugins []kernelPlugin `json:"plugins"`
}

// Roster returns the current plugin list: the streamed roster, enriched with
// the kernel's HTTP stats when they can be fetched.
//
// A kernel that does not answer is degraded, not an error. The stream alone
// already carries id, name, state and detail — the four things a human asks
// for first — and reporting Stats=false is more useful than reporting
// nothing.
func (s *Session) Roster(ctx context.Context) (Roster, error) {
	r, err := s.awaitRoster(ctx)
	if err != nil {
		return Roster{}, err
	}
	stats, err := s.kernelPlugins(ctx)
	if err != nil {
		return r, nil
	}
	return mergeStats(r, stats), nil
}

// WatchRoster delivers every roster the stream pushes, starting with the
// current one if there is one. The channel is closed when ctx is cancelled or
// the session is closed, so ranging over it terminates without a second
// signal.
func (s *Session) WatchRoster(ctx context.Context) (<-chan Roster, error) {
	ch := make(chan Roster, 1)

	s.mu.Lock()
	if s.ctx.Err() != nil {
		s.mu.Unlock()
		return nil, Errorf("session closed")
	}
	s.watchers[ch] = struct{}{}
	if s.have {
		ch <- s.roster
	}
	s.mu.Unlock()

	go func() {
		select {
		case <-ctx.Done():
		case <-s.ctx.Done():
		}
		// Deregistering under the same lock the publisher holds is what makes
		// the close below safe: no send can be in flight once this returns.
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, live := s.watchers[ch]; live {
			delete(s.watchers, ch)
			close(ch)
		}
	}()

	return ch, nil
}

// RestartPlugin asks the kernel to respawn a plugin. The supervisor owns the
// lifecycle; this client only asks.
func (s *Session) RestartPlugin(ctx context.Context, id string) error {
	if id == "" {
		return Usagef("plugin id required")
	}
	resp, err := s.kernelDo(ctx, http.MethodPost, kernelPluginsPath+"/"+id+"/restart")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	switch {
	case resp.StatusCode == http.StatusNotFound:
		return NotFound("plugin", id)
	// The kernel answers a successful restart with a 303 to its dashboard.
	case resp.StatusCode == http.StatusSeeOther, resp.StatusCode/100 == 2:
		return nil
	default:
		return Errorf("restart %s: kernel returned %s", id, resp.Status)
	}
}

// kernelPlugins fetches the kernel's own view of the roster, which is the
// only source of pid, uptime, restart count, probe latency, event counters
// and log path.
func (s *Session) kernelPlugins(ctx context.Context) ([]kernelPlugin, error) {
	resp, err := s.kernelDo(ctx, http.MethodGet, kernelPluginsPath)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, Errorf("kernel %s returned %s", kernelPluginsPath, resp.Status)
	}
	var body kernelStatus
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, Errorf("decode kernel plugin list: %v", err)
	}
	return body.Plugins, nil
}

func (s *Session) kernelDo(ctx context.Context, method, path string) (*http.Response, error) {
	base, token, err := s.kernelOrigin(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, method, base+path, nil)
	if err != nil {
		return nil, Errorf("build kernel request: %v", err)
	}
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})

	resp, err := s.http.Do(req)
	if err != nil {
		return nil, Unreachable(base, err)
	}
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		return nil, Errorf("kernel rejected the session token; core may have restarted")
	}
	return resp, nil
}

// rosterFromStream converts a PluginList. Every stats field stays zero and
// Stats stays false: the stream carries identity and state, never numbers.
func rosterFromStream(list *clientv1.PluginList) Roster {
	r := Roster{
		Plugins: make([]Plugin, 0, len(list.GetPlugins())),
		BaseURL: list.GetBaseUrl(),
	}
	for _, p := range list.GetPlugins() {
		r.Plugins = append(r.Plugins, Plugin{
			ID:     p.GetId(),
			Name:   p.GetName(),
			Icon:   p.GetIcon(),
			Path:   p.GetPath(),
			State:  stateFromProto(p.GetState()),
			Detail: p.GetDetail(),
		})
	}
	return r
}

// mergeStats folds the kernel's numbers into the streamed roster. The stream
// decides which plugins exist — it is the client contract, and it is what
// hides `ui: none` plugins — while the kernel decides what they are doing,
// including state, which it read a moment more recently than the stream did.
//
// Icon exists only on the stream and log_path only in the kernel JSON, so
// neither side is redundant.
func mergeStats(r Roster, stats []kernelPlugin) Roster {
	byID := make(map[string]kernelPlugin, len(stats))
	for _, k := range stats {
		byID[k.ID] = k
	}
	out := r
	out.Plugins = make([]Plugin, len(r.Plugins))
	copy(out.Plugins, r.Plugins)

	for i, p := range out.Plugins {
		k, ok := byID[p.ID]
		if !ok {
			continue
		}
		p.UI = k.UI
		p.LogPath = k.LogPath
		p.Dir = k.Dir
		p.Build = k.Build
		p.State = stateFromKernel(k.State)
		p.Detail = k.Detail
		p.PID = k.PID
		p.UptimeSec = k.UptimeSec
		p.Restarts = k.Restarts
		p.ProbeLatencyMS = k.ProbeLatencyMS
		p.EventsPublished = k.EventsPublished
		p.EventsDelivered = k.EventsDelivered
		p.LastEventUnix = k.LastEventUnix
		p.Stats = true
		out.Plugins[i] = p
	}
	return out
}

// Tally counts the roster by state. Both `vibecare status` and the TUI
// sidebar need it, and neither should be reimplementing the arithmetic.
func (r Roster) Tally() Tally {
	t := Tally{Total: len(r.Plugins)}
	for _, p := range r.Plugins {
		switch p.State {
		case StateUp:
			t.Up++
		case StateDegraded:
			t.Degraded++
		case StateDown:
			t.Down++
		case StateFailed:
			t.Failed++
		case StateStarting:
			t.Starting++
		}
	}
	return t
}

func stateFromProto(s clientv1.State) State {
	switch s {
	case clientv1.State_UP:
		return StateUp
	case clientv1.State_DEGRADED:
		return StateDegraded
	case clientv1.State_DOWN:
		return StateDown
	case clientv1.State_FAILED:
		return StateFailed
	case clientv1.State_STARTING:
		return StateStarting
	default:
		return StateUnknown
	}
}

// stateFromKernel maps the kernel's lowercase JSON strings. An unrecognised
// value becomes UNKNOWN rather than being passed through, so a newer core
// cannot smuggle a state this client's callers never expected.
func stateFromKernel(s string) State {
	switch State(strings.ToUpper(s)) {
	case StateUp:
		return StateUp
	case StateDegraded:
		return StateDegraded
	case StateDown:
		return StateDown
	case StateFailed:
		return StateFailed
	case StateStarting:
		return StateStarting
	default:
		return StateUnknown
	}
}
