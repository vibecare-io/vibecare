package kernel

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"go.uber.org/zap"
)

var (
	// probeInterval is how often core asks each running plugin whether its
	// HTTP surface is still answering.
	probeInterval = 10 * time.Second
	// probeTimeout bounds a single probe. A plugin slower than this is, for
	// the purposes of "is the data plane responsive", not responsive.
	probeTimeout = 2 * time.Second
)

// probeFailThreshold is how many CONSECUTIVE failures a transition needs.
// Requiring three is what stops one slow probe from flapping the roster.
const probeFailThreshold = 3

type probeResult struct {
	ok               bool
	reportedDegraded bool
	detail           string
	latency          time.Duration
}

// healthBody is the optional JSON enrichment a plugin may return. The SDK
// registers a default handler that returns an empty 200, so most plugin
// authors never write any of this.
type healthBody struct {
	Status string `json:"status"` // "ok" | "degraded"
	Detail string `json:"detail"`
	Since  string `json:"since"`
}

// advance is the plugin health state machine, kept pure so it can be
// tested as a table without any I/O.
//
//	starting/up --3 failed probes--> degraded --3 more--> down
//	                  ^                  |
//	                  +-- probe recovers +
//
// A plugin that reports "degraded" from its own /health moves there
// immediately rather than waiting for probes to fail — it knows something
// core cannot observe.
func advance(cur State, r probeResult, fails int) (State, int) {
	if r.ok {
		if r.reportedDegraded {
			return StateDegraded, 0
		}
		return StateUp, 0
	}

	fails++
	switch cur {
	case StateStarting, StateUp:
		if fails >= probeFailThreshold {
			return StateDegraded, 0
		}
		return cur, fails
	case StateDegraded:
		if fails >= probeFailThreshold {
			return StateDown, 0
		}
		return StateDegraded, fails
	default:
		// down/failed belong to the supervisor; the prober only counts.
		return cur, fails
	}
}

// probeHealth performs one GET /health against a plugin's loopback port.
func probeHealth(ctx context.Context, c *http.Client, port uint32) probeResult {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()

	url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return probeResult{}
	}

	start := time.Now()
	resp, err := c.Do(req)
	latency := time.Since(start)
	if err != nil {
		return probeResult{latency: latency}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return probeResult{latency: latency, detail: resp.Status}
	}

	out := probeResult{ok: true, latency: latency}
	// Body is optional. Cap the read: a plugin returning megabytes from
	// /health is misbehaving and must not be able to stall the prober.
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	if err != nil || len(b) == 0 {
		return out
	}
	var body healthBody
	if err := json.Unmarshal(b, &body); err != nil {
		return out // free-form body is fine; 200 already answered the question
	}
	out.detail = body.Detail
	out.reportedDegraded = body.Status == "degraded"
	return out
}

// Health probes every running plugin's data plane on a timer. It never
// restarts anything: a degraded process is alive and may hold unflushed
// state, so terminating it is a user decision, not a timer's.
type Health struct {
	reg    *Registry
	log    *zap.Logger
	client *http.Client

	mu    sync.Mutex
	fails map[string]int
}

func NewHealth(reg *Registry, log *zap.Logger) *Health {
	return &Health{
		reg:    reg,
		log:    log,
		client: &http.Client{},
		fails:  map[string]int{},
	}
}

// Start runs ProbeOnce on a ticker until ctx is cancelled.
func (h *Health) Start(ctx context.Context) {
	go func() {
		t := time.NewTicker(probeInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				h.ProbeOnce(ctx)
			}
		}
	}()
}

// ProbeOnce probes every plugin that is running and has a known port, in
// parallel, and applies the state machine to each result.
func (h *Health) ProbeOnce(ctx context.Context) {
	var wg sync.WaitGroup
	for _, stat := range h.reg.Snapshot() {
		if stat.State != StateUp && stat.State != StateDegraded {
			continue
		}
		port, ok := h.reg.Port(stat.ID)
		if !ok {
			continue
		}
		wg.Add(1)
		go func(id string, observed State, port uint32) {
			defer wg.Done()
			r := probeHealth(ctx, h.client, port)
			h.reg.SetProbeLatency(id, r.latency)

			h.mu.Lock()
			next, fails := advance(observed, r, h.fails[id])
			h.mu.Unlock()

			detail := r.detail
			if next == StateUp {
				detail = ""
			}
			if next == observed && detail == "" {
				// Nothing to commit to the registry, just the local
				// failure count (e.g. one bad probe that hasn't reached
				// threshold yet).
				h.mu.Lock()
				h.fails[id] = fails
				h.mu.Unlock()
				return
			}

			// Commit atomically against the state this probe actually
			// observed before it went out on the wire (probeHealth can
			// take up to probeTimeout). If another writer — the
			// supervisor, most likely — has since moved the plugin away
			// from `observed`, CompareAndSetState refuses the write, and
			// this goroutine must not resurrect the plugin with a state
			// computed from an assumption that no longer holds.
			if h.reg.CompareAndSetState(id, observed, next, detail) {
				h.mu.Lock()
				h.fails[id] = fails
				h.mu.Unlock()
				return
			}

			// Dropped: `observed` is stale, so is everything computed
			// from it, including fails — do not store it. Don't retry,
			// either: the next probe is only probeInterval away and will
			// read the plugin's true current state fresh, whereas
			// retrying immediately here would just re-run the same race
			// against a supervisor that has every right to win it.
			h.mu.Lock()
			delete(h.fails, id)
			h.mu.Unlock()
		}(stat.ID, stat.State, port)
	}
	wg.Wait()
}

// Reset clears a plugin's failure count. The RPC layer calls this when a
// plugin (re)registers, so a fresh process starts with a clean slate.
func (h *Health) Reset(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.fails, id)
}
