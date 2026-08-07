package plugins

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	statusReady       = "ready"
	statusUnavailable = "unavailable"

	// healthInterval is how often each loaded plugin is polled with
	// HealthCheck.
	healthInterval = 10 * time.Second

	// maxRestartAttempts caps how many times a failing plugin is
	// automatically restarted before it's left "unavailable" for good.
	maxRestartAttempts = 5

	// launchTimeout bounds how long we wait for a plugin to report its
	// listen address (production launcher) or otherwise become dialable.
	launchTimeout = 5 * time.Second

	// rpcTimeout bounds individual setup/health RPCs to a plugin.
	rpcTimeout = 5 * time.Second
)

// PluginInfo is a summary of a loaded plugin, exposed via Registry.List().
type PluginInfo struct {
	ID      string
	Name    string
	Icon    string
	UIKind  string
	UIEntry string
	Status  string // "ready" | "unavailable"
}

// launcher starts a plugin (an OS subprocess in production, an in-process
// stub server in tests) and returns the gRPC address to dial plus a stop
// func to shut it down. This is the seam that lets Registry be tested
// without spawning real subprocesses.
type launcher interface {
	launch(ctx context.Context, dir string, m FileManifest, hostAddr string) (addr string, stop func(), err error)
}

// execLauncher is the production launcher: it runs the plugin's exec binary
// (resolved relative to the plugin's own directory) as an OS subprocess,
// passes Core's host address via --host, and reads the plugin's own listen
// address from the first line the plugin writes to stdout. This handshake
// is intentionally minimal — the Task 6 SDK is responsible for the plugin
// side of it (start a gRPC server, print "host:port\n" to stdout, then keep
// running).
type execLauncher struct{}

func (execLauncher) launch(ctx context.Context, dir string, m FileManifest, hostAddr string) (string, func(), error) {
	binPath := filepath.Join(dir, m.Exec)
	if _, err := os.Stat(binPath); err != nil {
		return "", nil, fmt.Errorf("plugin exec not found at %s: %w", binPath, err)
	}

	cmd := exec.Command(binPath, "--host", hostAddr)
	cmd.Dir = dir
	// The plugin's stderr flows straight to Core's own stderr. There's no
	// prefixing/capture here, so interleaved plugin logs are a known
	// readability hazard — acceptable for v1, revisit if it gets noisy.
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", nil, fmt.Errorf("stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", nil, fmt.Errorf("start plugin process: %w", err)
	}

	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			if cmd.Process != nil {
				_ = cmd.Process.Kill()
			}
			_ = cmd.Wait()
		})
	}

	type result struct {
		addr string
		err  error
	}
	resultCh := make(chan result, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		if scanner.Scan() {
			resultCh <- result{addr: strings.TrimSpace(scanner.Text())}
			return
		}
		resultCh <- result{err: fmt.Errorf("plugin exited before printing listen address: %w", scanner.Err())}
	}()

	select {
	case res := <-resultCh:
		if res.err != nil {
			stop()
			return "", nil, res.err
		}
		if res.addr == "" {
			stop()
			return "", nil, fmt.Errorf("plugin printed empty listen address")
		}
		return res.addr, stop, nil
	case <-time.After(launchTimeout):
		stop()
		return "", nil, fmt.Errorf("timed out after %s waiting for plugin to print listen address", launchTimeout)
	case <-ctx.Done():
		stop()
		return "", nil, ctx.Err()
	}
}

// loadedPlugin is a plugin Registry has successfully launched and dialed.
// dir and manifest are retained so the health poller can relaunch it later.
type loadedPlugin struct {
	dir      string
	manifest FileManifest

	mu       sync.Mutex
	info     PluginInfo
	client   pb.PluginServiceClient
	conn     *grpc.ClientConn
	stop     func()
	attempts int
}

func (lp *loadedPlugin) snapshot() PluginInfo {
	lp.mu.Lock()
	defer lp.mu.Unlock()
	return lp.info
}

// Registry discovers plugin manifests under a directory, launches and
// supervises each plugin's subprocess, and exposes their gRPC clients.
type Registry struct {
	dir      string
	host     *HostService //nolint:unused // retained for future host-side wiring; not consumed directly by Registry yet
	hostAddr string
	log      *zap.Logger
	launcher launcher

	mu      sync.RWMutex
	plugins map[string]*loadedPlugin

	stopOnce   sync.Once
	stopHealth chan struct{}
	wg         sync.WaitGroup
}

// NewRegistry constructs a Registry that launches plugins found under dir
// using the production os/exec-based launcher.
func NewRegistry(dir string, host *HostService, hostAddr string, log *zap.Logger) *Registry {
	return newRegistryWithLauncher(dir, host, hostAddr, log, execLauncher{})
}

// newRegistryWithLauncher is the injectable constructor used by tests to
// swap in a fake launcher that avoids real OS subprocesses.
func newRegistryWithLauncher(dir string, host *HostService, hostAddr string, log *zap.Logger, l launcher) *Registry {
	return &Registry{
		dir:        dir,
		host:       host,
		hostAddr:   hostAddr,
		log:        log,
		launcher:   l,
		plugins:    make(map[string]*loadedPlugin),
		stopHealth: make(chan struct{}),
	}
}

// Start scans dir/*/manifest.yaml, launching and dialing each plugin it
// finds. A single bad plugin (missing exec, unparseable manifest, launch or
// dial failure) is logged and skipped; it never aborts loading the others.
func (r *Registry) Start(ctx context.Context) error {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		if os.IsNotExist(err) {
			r.log.Info("plugins directory does not exist; nothing to load", zap.String("dir", r.dir))
			return nil
		}
		return fmt.Errorf("read plugins dir: %w", err)
	}

	// os.ReadDir already returns entries sorted by filename, but sort
	// explicitly so "the first plugin discovered" (load-order-sensitive: see
	// the single-plugin guard in loadOne, and the duplicate-id skip) is a
	// documented, stable property of Registry rather than an incidental one
	// borrowed from os.ReadDir's current contract.
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pluginDir := filepath.Join(r.dir, e.Name())
		manifestPath := filepath.Join(pluginDir, "manifest.yaml")
		if _, statErr := os.Stat(manifestPath); statErr != nil {
			continue // not a plugin directory
		}
		if loadErr := r.loadOne(ctx, pluginDir, manifestPath); loadErr != nil {
			r.log.Warn("skipping plugin", zap.String("dir", pluginDir), zap.Error(loadErr))
		}
	}

	return nil
}

// loadOne parses, launches, dials, and initializes a single plugin, then
// records it and starts its health poller.
func (r *Registry) loadOne(ctx context.Context, dir, manifestPath string) error {
	m, err := loadManifestFile(manifestPath)
	if err != nil {
		return fmt.Errorf("load manifest: %w", err)
	}
	if m.ID == "" {
		return fmt.Errorf("manifest missing required field: id")
	}
	if m.Exec == "" {
		return fmt.Errorf("manifest missing required field: exec")
	}

	r.mu.RLock()
	_, dup := r.plugins[m.ID]
	loadedCount := len(r.plugins)
	r.mu.RUnlock()
	if dup {
		return fmt.Errorf("duplicate plugin id %s (already loaded from another directory); skipping %s", m.ID, dir)
	}

	// KNOWN LIMITATION (v1): HostService namespaces StoreData/QueryData/
	// DeleteData by a plugin id read from context (see WithPluginID in
	// host_service.go), but nothing in production wires that id yet —
	// cmd/server/main.go registers HostService with no interceptor, and the
	// SDK's HostClient sends no id. Every real call is therefore attributed
	// to the empty plugin id. With exactly one plugin loaded that's
	// harmless; with two, a second plugin that reuses a collection name
	// would silently corrupt or leak the first plugin's data. Until the
	// SDK-sends-id + host-interceptor wiring lands (first task of the next
	// slice), Registry only allows the first distinct plugin id discovered
	// (see the sorted os.ReadDir above for "first") to load; every other
	// distinct id is refused here, loudly, rather than silently corrupting
	// data.
	if loadedCount > 0 {
		r.log.Warn("plugin skipped: multi-plugin disabled until per-plugin storage namespacing is wired in production (known limitation); only one plugin can run safely because all plugins currently share the empty plugin_id namespace",
			zap.String("plugin_id", m.ID),
			zap.String("dir", dir))
		return fmt.Errorf("single-plugin guard: refusing to load second distinct plugin id %s (known limitation: production HostService namespacing is not yet wired, see docs/superpowers/specs/2026-08-06-plugin-system-v1-design.md#known-limitations-v1); skipping %s", m.ID, dir)
	}

	launchCtx, cancel := context.WithTimeout(ctx, launchTimeout)
	defer cancel()

	addr, stop, err := r.launcher.launch(launchCtx, dir, m, r.hostAddr)
	if err != nil {
		return fmt.Errorf("launch %s: %w", m.ID, err)
	}

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		stop()
		return fmt.Errorf("dial %s at %s: %w", m.ID, addr, err)
	}

	client := pb.NewPluginServiceClient(conn)

	if err := r.initializePlugin(ctx, client, m); err != nil {
		_ = conn.Close()
		stop()
		return fmt.Errorf("initialize %s: %w", m.ID, err)
	}

	lp := &loadedPlugin{
		dir:      dir,
		manifest: m,
		info: PluginInfo{
			ID:      m.ID,
			Name:    m.Name,
			Icon:    m.Icon,
			UIKind:  m.UI.Kind,
			UIEntry: m.UI.Entry,
			Status:  statusReady,
		},
		client: client,
		conn:   conn,
		stop:   stop,
	}

	r.mu.Lock()
	r.plugins[m.ID] = lp
	r.mu.Unlock()

	r.wg.Add(1)
	go r.healthLoop(lp)

	return nil
}

// initializePlugin calls GetManifest (to confirm the plugin is actually
// serving PluginService) followed by Initialize.
func (r *Registry) initializePlugin(ctx context.Context, client pb.PluginServiceClient, m FileManifest) error {
	getCtx, cancel := context.WithTimeout(ctx, rpcTimeout)
	defer cancel()
	if _, err := client.GetManifest(getCtx, &emptypb.Empty{}); err != nil {
		return fmt.Errorf("get manifest: %w", err)
	}

	initCtx, cancel2 := context.WithTimeout(ctx, rpcTimeout)
	defer cancel2()
	if _, err := client.Initialize(initCtx, &pb.InitRequest{HostAddress: r.hostAddr, PluginId: m.ID}); err != nil {
		return fmt.Errorf("initialize: %w", err)
	}

	return nil
}

// List returns a snapshot of every loaded plugin's info.
func (r *Registry) List() []PluginInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()

	out := make([]PluginInfo, 0, len(r.plugins))
	for _, lp := range r.plugins {
		out = append(out, lp.snapshot())
	}
	return out
}

// Client returns the gRPC client for a loaded plugin by id.
func (r *Registry) Client(id string) (pb.PluginServiceClient, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	lp, ok := r.plugins[id]
	if !ok {
		return nil, false
	}

	lp.mu.Lock()
	defer lp.mu.Unlock()
	return lp.client, true
}

// Stop halts health polling and kills every loaded plugin's subprocess. It
// is safe to call at most once; a second call is a no-op.
func (r *Registry) Stop() {
	r.stopOnce.Do(func() {
		close(r.stopHealth)
	})
	r.wg.Wait()

	r.mu.Lock()
	defer r.mu.Unlock()
	for _, lp := range r.plugins {
		lp.mu.Lock()
		if lp.conn != nil {
			_ = lp.conn.Close()
		}
		if lp.stop != nil {
			lp.stop()
		}
		lp.mu.Unlock()
	}
}

// healthLoop polls a single plugin's HealthCheck every healthInterval. On
// failure it marks the plugin unavailable and attempts a capped number of
// restarts with exponential backoff; on sustained failure it leaves the
// plugin unavailable rather than retrying forever.
func (r *Registry) healthLoop(lp *loadedPlugin) {
	defer r.wg.Done()

	ticker := time.NewTicker(healthInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.stopHealth:
			return
		case <-ticker.C:
			r.checkHealth(lp)
		}
	}
}

func (r *Registry) checkHealth(lp *loadedPlugin) {
	lp.mu.Lock()
	client := lp.client
	lp.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), rpcTimeout)
	health, err := client.HealthCheck(ctx, &emptypb.Empty{})
	cancel()

	if err == nil && health.GetOk() {
		lp.mu.Lock()
		lp.info.Status = statusReady
		lp.attempts = 0
		lp.mu.Unlock()
		return
	}

	r.log.Warn("plugin health check failed",
		zap.String("plugin_id", lp.manifest.ID),
		zap.Error(err))

	lp.mu.Lock()
	lp.info.Status = statusUnavailable
	attempts := lp.attempts
	lp.mu.Unlock()

	if attempts >= maxRestartAttempts {
		r.log.Error("plugin exceeded max restart attempts; leaving unavailable",
			zap.String("plugin_id", lp.manifest.ID))
		return
	}

	backoff := time.Duration(1<<attempts) * time.Second
	if backoff > 30*time.Second {
		backoff = 30 * time.Second
	}

	select {
	case <-time.After(backoff):
	case <-r.stopHealth:
		return
	}

	r.restart(lp)
}

// restart tears down a plugin's current process/connection (if any) and
// relaunches it from its retained dir/manifest.
func (r *Registry) restart(lp *loadedPlugin) {
	lp.mu.Lock()
	lp.attempts++
	oldStop := lp.stop
	oldConn := lp.conn
	lp.mu.Unlock()

	if oldStop != nil {
		oldStop()
	}
	if oldConn != nil {
		_ = oldConn.Close()
	}

	ctx, cancel := context.WithTimeout(context.Background(), launchTimeout)
	defer cancel()

	addr, stop, err := r.launcher.launch(ctx, lp.dir, lp.manifest, r.hostAddr)
	if err != nil {
		r.log.Warn("plugin restart: launch failed",
			zap.String("plugin_id", lp.manifest.ID), zap.Error(err))
		return
	}

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		stop()
		r.log.Warn("plugin restart: dial failed",
			zap.String("plugin_id", lp.manifest.ID), zap.Error(err))
		return
	}

	client := pb.NewPluginServiceClient(conn)
	if err := r.initializePlugin(ctx, client, lp.manifest); err != nil {
		_ = conn.Close()
		stop()
		r.log.Warn("plugin restart: initialize failed",
			zap.String("plugin_id", lp.manifest.ID), zap.Error(err))
		return
	}

	lp.mu.Lock()
	lp.client = client
	lp.conn = conn
	lp.stop = stop
	lp.info.Status = statusReady
	lp.mu.Unlock()

	r.log.Info("plugin restarted successfully", zap.String("plugin_id", lp.manifest.ID))
}
