// Package vc is the Go SDK for authoring VibeCare plugins.
//
// A plugin is a subprocess that core spawns. It is ALWAYS a gRPC client and
// NEVER a gRPC server: it serves HTTP for its UI and makes three outbound
// calls (Register, Publish, Alert). That asymmetry is what keeps plugins
// cheap to write in any language — there are no service stubs to implement.
//
// The whole of a minimal plugin:
//
//	func main() {
//	    h, err := vc.Connect()          // reads env, registers, reconnects on drop,
//	    if err != nil { log.Fatal(err) } // serves /health, returns handle + listener
//	    http.HandleFunc("/", serveUI)
//	    http.Serve(h.Listener, nil)
//	}
package vc

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var (
	// reconnectBase is the first reconnect delay; it doubles up to
	// reconnectMax. A var so tests can shrink it.
	reconnectBase = time.Second
	reconnectMax  = 30 * time.Second
	// readyTimeout bounds how long Connect waits for core's Ready. Core
	// kills an unregistered plugin after 10s anyway.
	readyTimeout = 10 * time.Second
)

// eventChanCap bounds the plugin's inbound queue. Events are
// fire-and-forget; a plugin that stops reading drops them rather than
// growing without bound.
const eventChanCap = 64

// Event is one delivery from the bus.
type Event struct {
	Topic   string
	Payload []byte
	TS      time.Time
}

// AlertAction is a button. URL is plugin-relative: pressing it navigates
// the client to /p/<plugin>/<url>.
type AlertAction struct {
	Label string
	URL   string
}

// Alert is a native, transient notification. It is the one UI path that is
// not HTML, because it must render with no window open.
type Alert struct {
	Title   string
	Body    string
	Level   string // "info" | "warn"
	Actions []AlertAction
}

// Handle is a connected plugin.
type Handle struct {
	ID       string
	DataDir  string
	Listener net.Listener

	// Events delivers bus events the plugin subscribed to in its manifest.
	// It is never closed — not by Close, not on shutdown — so a plugin
	// that ranges over Events expecting the loop to end on its own will
	// block forever after Close instead of seeing the channel close.
	// OnShutdown, not channel closure, is the termination signal.
	Events <-chan Event

	conn   *grpc.ClientConn
	client pluginv1.PluginHostClient
	events chan Event

	ctx    context.Context
	cancel context.CancelFunc

	mu         sync.Mutex
	onShutdown func()
	healthFn   func() (status, detail string)
}

// Connect reads the spawn environment, binds the plugin's HTTP listener,
// dials core, registers, and starts the reconnect loop. It returns once
// core has acknowledged with Ready.
//
// A plugin process is expected to call Connect exactly once. A second
// Connect in the same process is not an error: it does not fail or
// panic, it simply repoints the /health handler already installed on
// http.DefaultServeMux at the newer Handle (see registerDefaultHealth).
func Connect() (*Handle, error) {
	socket := os.Getenv("VIBECARE_SOCKET")
	id := os.Getenv("VIBECARE_PLUGIN_ID")
	dataDir := os.Getenv("VIBECARE_DATA_DIR")
	if socket == "" || id == "" || dataDir == "" {
		return nil, fmt.Errorf("vc: VIBECARE_SOCKET, VIBECARE_PLUGIN_ID and VIBECARE_DATA_DIR must all be set (is this plugin being run outside VibeCare?)")
	}

	// Bind before registering: RegisterReq.http_port must carry the port
	// the kernel actually assigned.
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("vc: bind plugin http listener: %w", err)
	}

	conn, err := grpc.NewClient("unix://"+socket,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(attributionInterceptor(id)),
		grpc.WithStreamInterceptor(attributionStreamInterceptor(id)),
	)
	if err != nil {
		lis.Close()
		return nil, fmt.Errorf("vc: dial core: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	h := &Handle{
		ID: id, DataDir: dataDir, Listener: lis,
		conn: conn, client: pluginv1.NewPluginHostClient(conn),
		events: make(chan Event, eventChanCap),
		ctx:    ctx, cancel: cancel,
	}
	h.Events = h.events

	// The default /health handler, so most plugin authors write none. A
	// plugin process calls Connect exactly once in production, but this
	// package's own tests call it many times against the single
	// process-wide http.DefaultServeMux, and *ServeMux.HandleFunc panics
	// on a duplicate pattern. Register the indirection handler at most
	// once and repoint it at the latest Handle on every call instead.
	registerDefaultHealth(h)

	ready := make(chan struct{})
	var readyOnce sync.Once
	go h.run(func() { readyOnce.Do(func() { close(ready) }) })

	select {
	case <-ready:
		return h, nil
	case <-time.After(readyTimeout):
		h.Close()
		return nil, fmt.Errorf("vc: core did not acknowledge registration within %s", readyTimeout)
	}
}

// run owns the Register stream for the life of the process. A dropped
// stream is NOT fatal: the plugin keeps serving HTTP and re-dials with
// backoff. Without this, restarting core would kill every running plugin.
func (h *Handle) run(onReady func()) {
	delay := reconnectBase
	for {
		if h.ctx.Err() != nil {
			return
		}
		if err := h.session(onReady); err != nil && h.ctx.Err() == nil {
			// stderr only: stdout belongs to the plugin author.
			fmt.Fprintf(os.Stderr, "vc: register stream ended (%v); reconnecting in %s\n", err, delay)
		}
		if h.ctx.Err() != nil {
			return
		}
		select {
		case <-h.ctx.Done():
			return
		case <-time.After(delay):
		}
		if delay < reconnectMax {
			delay *= 2
			if delay > reconnectMax {
				delay = reconnectMax
			}
		}
	}
}

// session runs one Register stream to completion.
func (h *Handle) session(onReady func()) error {
	_, portStr, err := net.SplitHostPort(h.Listener.Addr().String())
	if err != nil {
		return err
	}
	var port int
	if _, err := fmt.Sscanf(portStr, "%d", &port); err != nil {
		return err
	}

	stream, err := h.client.Register(h.ctx, &pluginv1.RegisterReq{
		Id: h.ID, HttpPort: uint32(port),
	})
	if err != nil {
		return err
	}

	for {
		msg, err := stream.Recv()
		if err != nil {
			return err
		}
		switch {
		case msg.GetReady() != nil:
			onReady()

		case msg.GetEvent() != nil:
			e := msg.GetEvent()
			select {
			case h.events <- Event{Topic: e.GetTopic(), Payload: e.GetPayload(), TS: e.GetTs().AsTime()}:
			default: // fire-and-forget: a plugin that isn't reading drops events
			}

		case msg.GetShutdown() != nil:
			h.mu.Lock()
			fn := h.onShutdown
			h.mu.Unlock()
			if fn != nil {
				fn()
			}
		}
	}
}

// Publish puts raw bytes on a topic. The topic must be declared in the
// plugin's manifest under publishes, or core rejects it.
func (h *Handle) Publish(topic string, payload []byte) error {
	_, err := h.client.Publish(h.ctx, &pluginv1.Event{
		Topic:   topic,
		Payload: payload,
		Ts:      timestamppb.Now(),
	})
	return err
}

// PublishProto marshals m and publishes it. Topic payloads evolve by
// bumping the version in the topic name, never by changing a message in
// place.
func (h *Handle) PublishProto(topic string, m proto.Message) error {
	b, err := proto.Marshal(m)
	if err != nil {
		return err
	}
	return h.Publish(topic, b)
}

func (h *Handle) Alert(a Alert) error {
	req := &pluginv1.AlertReq{Title: a.Title, Body: a.Body, Level: a.Level}
	for _, act := range a.Actions {
		req.Actions = append(req.Actions, &pluginv1.AlertAction{Label: act.Label, Url: act.URL})
	}
	_, err := h.client.Alert(h.ctx, req)
	return err
}

// OnShutdown registers a callback run when core sends Shutdown. Plugins
// should close their HTTP listener and flush storage there; SIGTERM
// follows, and SIGKILL 5s after that.
func (h *Handle) OnShutdown(fn func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.onShutdown = fn
}

// SetHealth overrides the default /health body. status is "ok" or
// "degraded"; a plugin reporting degraded moves to that state immediately
// rather than waiting for probes to fail.
func (h *Handle) SetHealth(fn func() (status, detail string)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.healthFn = fn
}

var (
	defaultHealthOnce sync.Once
	defaultHealthMu   sync.Mutex
	defaultHealthH    *Handle
)

// registerDefaultHealth wires http.DefaultServeMux's /health to whichever
// Handle most recently connected. The mux registration itself happens at
// most once per process; the target Handle is swapped under a mutex so a
// second Connect (a process reconnecting, or this package's own tests)
// never panics on a duplicate pattern.
func registerDefaultHealth(h *Handle) {
	defaultHealthMu.Lock()
	defaultHealthH = h
	defaultHealthMu.Unlock()

	defaultHealthOnce.Do(func() {
		http.DefaultServeMux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
			defaultHealthMu.Lock()
			cur := defaultHealthH
			defaultHealthMu.Unlock()
			if cur == nil {
				http.NotFound(w, r)
				return
			}
			cur.handleHealth(w, r)
		})
	})
}

func (h *Handle) handleHealth(w http.ResponseWriter, _ *http.Request) {
	h.mu.Lock()
	fn := h.healthFn
	h.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	status, detail := "ok", ""
	if fn != nil {
		status, detail = fn()
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"status": status, "detail": detail})
}

// Serve installs the default /health handler on mux and serves the
// plugin's HTTP on the listener core assigned. Passing nil uses
// http.DefaultServeMux, where Connect already installed /health.
//
// Passing http.DefaultServeMux explicitly is also safe: Connect already
// registered /health there, and *http.ServeMux.HandleFunc panics on a
// duplicate pattern, so Serve detects that case and repoints the
// existing indirection at this Handle instead of registering again.
func (h *Handle) Serve(mux *http.ServeMux) error {
	if mux == nil {
		return http.Serve(h.Listener, nil)
	}
	if mux == http.DefaultServeMux {
		defaultHealthMu.Lock()
		defaultHealthH = h
		defaultHealthMu.Unlock()
	} else {
		mux.HandleFunc("/health", h.handleHealth)
	}
	return http.Serve(h.Listener, mux)
}

func (h *Handle) Close() error {
	h.cancel()
	if h.Listener != nil {
		h.Listener.Close()
	}
	return h.conn.Close()
}

// attributionInterceptor attaches the plugin id to every unary call. Core
// uses it to attribute publishes and alerts; Event carries no plugin field
// precisely so a plugin cannot claim to be another one.
func attributionInterceptor(id string) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

func attributionStreamInterceptor(id string) grpc.StreamClientInterceptor {
	return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
		ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
		return streamer(ctx, desc, cc, method, opts...)
	}
}
