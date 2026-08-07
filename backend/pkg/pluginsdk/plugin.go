// Package pluginsdk is the Go SDK for authoring VibeCare plugins. A plugin
// author constructs a Plugin with New, registers action and render
// handlers with OnAction/OnRender, and calls Run — the SDK handles the
// gRPC serve loop, the handshake with Core, and dispatch.
//
// # Stdout discipline
//
// Run prints the plugin's resolved "host:port" listen address as the
// FIRST and ONLY line written to stdout, then never writes to stdout
// again for the life of the process. Core's launcher (see
// backend/internal/plugins.execLauncher) reads exactly one line from the
// subprocess's stdout pipe and never drains it again; any further stdout
// output would eventually fill the OS pipe buffer and deadlock the
// plugin. All plugin logging — including anything OnAction/OnRender
// handlers do — must go to stderr instead.
package pluginsdk

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sync"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
	"gopkg.in/yaml.v3"
)

// pluginIDInterceptor returns a client-side unary interceptor that attaches
// the plugin's id as pluginwire.PluginIDMetadataKey call metadata on every
// outbound HostService call, so Core can attribute (and namespace) it. An
// empty id appends nothing, preserving the standalone/no-manifest-id behavior.
func pluginIDInterceptor(pluginID string) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		if pluginID != "" {
			ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, pluginID)
		}
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

// fileManifest is the on-disk manifest.yaml shape. It intentionally
// mirrors backend/internal/plugins.FileManifest field-for-field rather
// than importing it: internal/plugins only exports the FileManifest type,
// not its yaml parsing helpers (parseManifestYAML/loadManifestFile are
// unexported), so re-declaring this small struct here is simpler than
// changing Core-internal visibility just so the SDK can reuse a few lines
// of yaml.Unmarshal plumbing.
type fileManifest struct {
	ID       string `yaml:"id"`
	Name     string `yaml:"name"`
	Version  string `yaml:"version"`
	Icon     string `yaml:"icon"`
	Exec     string `yaml:"exec"`
	Provides struct {
		Actions []string `yaml:"actions"`
		Events  []string `yaml:"events"`
		Data    []string `yaml:"data"`
	} `yaml:"provides"`
	UI struct {
		Kind  string `yaml:"kind"`
		Entry string `yaml:"entry"`
	} `yaml:"ui"`
}

// toProto converts the on-disk manifest into the wire pb.Manifest that
// GetManifest returns.
func (m fileManifest) toProto() *pb.Manifest {
	return &pb.Manifest{
		Id:      m.ID,
		Name:    m.Name,
		Version: m.Version,
		Icon:    m.Icon,
		Actions: m.Provides.Actions,
		Events:  m.Provides.Events,
		Data:    m.Provides.Data,
		UiKind:  m.UI.Kind,
		UiEntry: m.UI.Entry,
	}
}

// Ctx is passed to every OnAction/OnRender handler and carries access back
// to Core via Host.
type Ctx struct {
	Host *HostClient
}

// Plugin is the SDK entry point. Construct with New, register handlers
// with OnAction/OnRender, then call Run.
type Plugin struct {
	pb.UnimplementedPluginServiceServer

	manifest fileManifest

	mu      sync.RWMutex
	actions map[string]func(Ctx, map[string]string) error
	renders map[string]func(Ctx) View

	host *HostClient
}

// New reads manifest.yaml from the current working directory and
// constructs a Plugin. It does not parse flags or touch stdout — that
// happens in Run, so New is safe to call in any context (including from a
// hypothetical future test that wants a real manifest.yaml on disk).
func New() *Plugin {
	data, err := os.ReadFile("manifest.yaml")
	if err != nil {
		fmt.Fprintf(os.Stderr, "pluginsdk: read manifest.yaml: %v\n", err)
		os.Exit(1)
	}

	var m fileManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		fmt.Fprintf(os.Stderr, "pluginsdk: parse manifest.yaml: %v\n", err)
		os.Exit(1)
	}

	return newPlugin(m)
}

// newPlugin is the unexported constructor shared by New and tests. Tests
// call it directly (with a hand-built fileManifest) to avoid needing a
// real manifest.yaml on disk and to avoid New's os.Exit-on-error behavior.
func newPlugin(m fileManifest) *Plugin {
	return &Plugin{
		manifest: m,
		actions:  make(map[string]func(Ctx, map[string]string) error),
		renders:  make(map[string]func(Ctx) View),
	}
}

// OnAction registers a handler invoked for both ExecuteAction and
// InvokeAction requests naming this action.
func (p *Plugin) OnAction(name string, fn func(Ctx, map[string]string) error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.actions[name] = fn
}

// OnRender registers a handler that builds the View for a given view id,
// invoked by RenderView and (for a whole-view refresh) after InvokeAction.
func (p *Plugin) OnRender(viewID string, fn func(Ctx) View) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.renders[viewID] = fn
}

// ctx builds the Ctx passed to handlers. p.host is set once during start
// and never mutated afterward, so reading it here needs no lock.
func (p *Plugin) ctx() Ctx {
	return Ctx{Host: p.host}
}

// Run parses the --host flag Core passes when launching the plugin
// subprocess, starts serving, prints the resolved listen address as the
// first (and only) stdout line, then blocks until the process is
// terminated. See the package doc for why nothing else may be written to
// stdout after that line.
func (p *Plugin) Run() error {
	hostAddr := flag.String("host", "", "Core host gRPC address")
	flag.Parse()

	addr, stop, err := p.start(*hostAddr)
	if err != nil {
		return fmt.Errorf("start plugin: %w", err)
	}
	defer stop()

	// os.Stdout writes go straight to the underlying fd (no bufio
	// buffering in front of it), so this Fprintln is already flushed by
	// the time it returns — there is no separate flush step needed.
	if _, err := fmt.Fprintln(os.Stdout, addr); err != nil {
		return fmt.Errorf("write listen address to stdout: %w", err)
	}

	select {} // serve forever; the goroutine started in start() does the work
}

// start is the testability seam: it does everything Run does except flag
// parsing and the stdout print, so tests can start a Plugin programmatically
// and learn its address without going through stdout. It starts a gRPC
// server for PluginService on an ephemeral localhost port, dials hostAddr
// (if non-empty) to build the HostClient, and returns the server's address
// plus a stop func.
func (p *Plugin) start(hostAddr string) (addr string, stop func(), err error) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, fmt.Errorf("listen: %w", err)
	}

	var hostConn *grpc.ClientConn
	if hostAddr != "" {
		hostConn, err = grpc.NewClient(hostAddr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithChainUnaryInterceptor(pluginIDInterceptor(p.manifest.ID)),
		)
		if err != nil {
			_ = lis.Close()
			return "", nil, fmt.Errorf("dial host at %s: %w", hostAddr, err)
		}
		p.host = &HostClient{client: pb.NewHostServiceClient(hostConn)}
	}

	srv := grpc.NewServer()
	pb.RegisterPluginServiceServer(srv, p)

	go func() {
		_ = srv.Serve(lis)
	}()

	var stopOnce sync.Once
	stopFn := func() {
		stopOnce.Do(func() {
			srv.Stop()
			if hostConn != nil {
				_ = hostConn.Close()
			}
		})
	}

	return lis.Addr().String(), stopFn, nil
}

// GetManifest returns the manifest parsed from manifest.yaml at construction.
func (p *Plugin) GetManifest(context.Context, *emptypb.Empty) (*pb.Manifest, error) {
	return p.manifest.toProto(), nil
}

// Initialize is a no-op in v1: the SDK has nothing to set up beyond what
// start already did (the host client is dialed from --host before
// Initialize would ever arrive).
func (p *Plugin) Initialize(context.Context, *pb.InitRequest) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

// HandleEvent is a no-op in v1: no plugin built with this SDK yet
// subscribes to host events.
func (p *Plugin) HandleEvent(context.Context, *pb.HostEvent) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

// ExecuteAction dispatches to the OnAction handler registered under
// req.Action. Unlike InvokeAction, it's fire-and-forget: no view is
// re-rendered, and an unknown action or handler error is reported via
// PluginExecuteActionResponse.Ok rather than a gRPC error.
func (p *Plugin) ExecuteAction(_ context.Context, req *pb.PluginExecuteActionRequest) (*pb.PluginExecuteActionResponse, error) {
	p.mu.RLock()
	fn, ok := p.actions[req.GetAction()]
	p.mu.RUnlock()
	if !ok {
		return &pb.PluginExecuteActionResponse{Ok: false, Message: fmt.Sprintf("unknown action %q", req.GetAction())}, nil
	}

	if err := fn(p.ctx(), req.GetParams()); err != nil {
		return &pb.PluginExecuteActionResponse{Ok: false, Message: err.Error()}, nil
	}
	return &pb.PluginExecuteActionResponse{Ok: true}, nil
}

// RenderView calls the OnRender handler registered under req.ViewId and
// returns its descriptor.
func (p *Plugin) RenderView(_ context.Context, req *pb.RenderViewRequest) (*pb.ViewDescriptor, error) {
	p.mu.RLock()
	fn, ok := p.renders[req.GetViewId()]
	p.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("unknown view %q", req.GetViewId())
	}
	return fn(p.ctx()).toProto(), nil
}

// InvokeAction dispatches to the OnAction handler registered under
// req.Action, then re-renders the view named by req.ViewId and returns it
// — the whole-view-refresh model (no diffing in v1).
func (p *Plugin) InvokeAction(_ context.Context, req *pb.InvokeActionRequest) (*pb.InvokeActionResponse, error) {
	p.mu.RLock()
	fn, ok := p.actions[req.GetAction()]
	p.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("unknown action %q", req.GetAction())
	}

	if err := fn(p.ctx(), req.GetParams()); err != nil {
		return nil, fmt.Errorf("action %q: %w", req.GetAction(), err)
	}

	p.mu.RLock()
	renderFn, ok := p.renders[req.GetViewId()]
	p.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("unknown view %q", req.GetViewId())
	}

	return &pb.InvokeActionResponse{View: renderFn(p.ctx()).toProto()}, nil
}

// HealthCheck always reports ok — the SDK has no internal health signal
// beyond "the process is up and answering gRPC calls".
func (p *Plugin) HealthCheck(context.Context, *emptypb.Empty) (*pb.Health, error) {
	return &pb.Health{Ok: true}, nil
}

// HostClient wraps the host-callback API (pb.HostServiceClient) with a
// friendlier surface for plugin authors: JSON marshaling for Store/Query,
// and one-line Notify/Emit calls.
type HostClient struct {
	client pb.HostServiceClient
}

// Store JSON-marshals v and upserts it under (collection, key) in this
// plugin's namespaced storage.
func (h *HostClient) Store(collection, key string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal value for %s/%s: %w", collection, key, err)
	}
	_, err = h.client.StoreData(context.Background(), &pb.StoreRequest{
		Collection: collection,
		Key:        key,
		ValueJson:  string(data),
	})
	return err
}

// Query returns every record this plugin has stored in collection.
func (h *HostClient) Query(collection string) ([]Record, error) {
	resp, err := h.client.QueryData(context.Background(), &pb.QueryRequest{Collection: collection})
	if err != nil {
		return nil, err
	}
	records := make([]Record, 0, len(resp.GetRecords()))
	for _, r := range resp.GetRecords() {
		records = append(records, Record{Key: r.GetKey(), ValueJSON: r.GetValueJson()})
	}
	return records, nil
}

// Delete removes the value stored under (collection, key) in this plugin's
// namespaced storage. Deleting a key that doesn't exist is a no-op.
func (h *HostClient) Delete(collection, key string) error {
	_, err := h.client.DeleteData(context.Background(), &pb.DeleteRequest{
		Collection: collection,
		Key:        key,
	})
	return err
}

// Notify surfaces a plugin-originated notification to the user.
func (h *HostClient) Notify(title, message string) error {
	_, err := h.client.Notify(context.Background(), &pb.NotifyRequest{Title: title, Message: message})
	return err
}

// Emit broadcasts a plugin-originated event of the given type with payload.
func (h *HostClient) Emit(eventType string, payload map[string]string) error {
	_, err := h.client.EmitEvent(context.Background(), &pb.PluginEvent{Type: eventType, Payload: payload})
	return err
}

// Record is one stored value as returned by HostClient.Query: the raw
// value_json alongside its key, so callers can pick their own unmarshal
// target (see AsMap for a generic one).
type Record struct {
	Key       string
	ValueJSON string
}

// AsMap unmarshals ValueJSON into a generic map, for callers that don't
// want to declare a concrete struct.
func (r Record) AsMap() (map[string]any, error) {
	var m map[string]any
	if err := json.Unmarshal([]byte(r.ValueJSON), &m); err != nil {
		return nil, fmt.Errorf("unmarshal record %s: %w", r.Key, err)
	}
	return m, nil
}
