package kernel

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// Config is everything the kernel needs from its environment. Note what is
// absent: no ports. Every listener binds 127.0.0.1:0 and the kernel reports
// what it got, so there is nothing to configure and nothing to collide with.
type Config struct {
	PluginsDir  string
	DataRoot    string
	SocketPath  string
	SessionPath string
}

// DefaultConfig places the kernel's runtime state under the user's
// ~/.vibecare directory, alongside the database and logs.
func DefaultConfig(home, pluginsDir string) Config {
	base := filepath.Join(home, ".vibecare")
	return Config{
		PluginsDir:  pluginsDir,
		DataRoot:    filepath.Join(base, "data"),
		SocketPath:  filepath.Join(base, "core.sock"),
		SessionPath: filepath.Join(base, "session"),
	}
}

// Kernel wires the registry, bus, supervisor, health prober, proxy,
// dashboard, and both gRPC surfaces into one startable unit.
type Kernel struct {
	cfg Config
	log *zap.Logger

	reg     *Registry
	bus     *Bus
	sup     *Supervisor
	health  *Health
	intents *Intents
	auth    *Auth
	host    *Host
	shell   *ShellService

	httpSrv  *http.Server
	httpAddr string
	grpcSrv  *grpc.Server

	mu        sync.Mutex
	started   bool
	stopped   bool
	cancel    context.CancelFunc
	readyOnce sync.Once
	// ready is closed once Start has resolved the HTTP origin (or given up
	// trying to). BaseURL blocks on it, which is what stops a client that
	// connects to the shell service before Start finishes from ever
	// observing a placeholder or empty origin.
	ready chan struct{}
}

func New(cfg Config, log *zap.Logger) (*Kernel, error) {
	auth, err := NewAuth(cfg.SessionPath)
	if err != nil {
		return nil, err
	}

	reg := NewRegistry(log)
	bus := NewBus(log)
	// Attribute deliveries to the receiving plugin without the bus needing
	// to know the registry exists.
	bus.OnDelivered(func(id string, n int) { reg.CountDelivered(id, n) })

	sup := NewSupervisor(reg, cfg.SocketPath, cfg.DataRoot, log)
	health := NewHealth(reg, log)
	intents := NewIntents(log)

	k := &Kernel{
		cfg: cfg, log: log,
		reg: reg, bus: bus, sup: sup, health: health, intents: intents, auth: auth,
		ready: make(chan struct{}),
	}
	k.host = NewHost(reg, bus, sup, health, intents, log)
	// BaseURL is resolved per-send rather than captured, because
	// RegisterShell runs before Start knows the HTTP port.
	k.shell = NewShellService(reg, intents, k.BaseURL, auth.Token())
	return k, nil
}

func (k *Kernel) Registry() *Registry { return k.reg }
func (k *Kernel) Token() string       { return k.auth.Token() }

// closeReady unblocks anyone waiting in BaseURL. It is called once Start
// resolves the HTTP origin either way (bound, or failed trying), and again
// defensively from Stop so a caller that never calls Start at all still
// cannot wedge a BaseURL caller forever.
func (k *Kernel) closeReady() {
	k.readyOnce.Do(func() { close(k.ready) })
}

// BaseURL returns the kernel's loopback HTTP origin. It blocks until Start
// has resolved that origin (or given up), so a client that races ahead of
// Start — e.g. one that connects to the shell service the instant it is
// registered, before Start has bound anything — waits for the real answer
// instead of observing an empty string.
//
// It takes ctx because its only caller (ShellService, via a gRPC streaming
// handler) can itself be cancelled while waiting — a client that
// disconnects during the pre-Start window must not leave that handler
// blocked forever just because the kernel is slow to bind. ctx.Done()
// unblocks BaseURL with an empty string in that case; the stream handler
// is expected to treat an empty BaseUrl the same as "give up," which it
// does naturally since it's already exiting on ctx.Done() itself.
func (k *Kernel) BaseURL(ctx context.Context) string {
	select {
	case <-k.ready:
	case <-ctx.Done():
		return ""
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.httpAddr == "" {
		return ""
	}
	return "http://" + k.httpAddr
}

// RegisterShell installs the client-facing service on the app's existing
// TCP gRPC server — the connection clients already have. Safe to call
// before Start.
func (k *Kernel) RegisterShell(s *grpc.Server) {
	clientv1.RegisterShellServer(s, k.shell)
}

// Start discovers plugins, binds both listeners, and spawns everything.
func (k *Kernel) Start(ctx context.Context) error {
	k.mu.Lock()
	if k.started {
		k.mu.Unlock()
		return nil
	}
	k.started = true
	k.mu.Unlock()
	// Whatever happens below, once Start returns the HTTP origin question
	// is settled (bound, or never will be) — release anyone blocked in
	// BaseURL.
	defer k.closeReady()

	manifests, err := Discover(k.cfg.PluginsDir, k.log)
	if err != nil {
		return err
	}
	for _, m := range manifests {
		k.reg.Add(m)
		k.bus.Declare(m.ID, m.Subscribes, m.Publishes)
	}
	k.log.Info("discovered plugins",
		zap.String("dir", k.cfg.PluginsDir), zap.Int("count", len(manifests)))

	// Loopback HTTP: the proxy and the dashboard, both behind one auth
	// check. /_core/* is matched first and is never proxied.
	mux := http.NewServeMux()
	mux.Handle(corePrefix, NewStatusHandler(k.reg, k.sup))
	mux.Handle(proxyPrefix, NewProxy(k.reg, k.log))

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("bind kernel http: %w", err)
	}
	k.mu.Lock()
	k.httpAddr = lis.Addr().String()
	k.httpSrv = &http.Server{Handler: k.auth.Middleware(mux)}
	origin := "http://" + k.httpAddr
	k.mu.Unlock()
	go func() {
		if err := k.httpSrv.Serve(lis); err != nil && err != http.ErrServerClosed {
			k.log.Error("kernel http server stopped", zap.Error(err))
		}
	}()
	// Logged from the local origin var, not k.BaseURL(): BaseURL blocks on
	// k.ready, which this very call is still inside of (the defer above
	// hasn't run yet) — calling it here would deadlock Start against itself.
	k.log.Info("kernel http listening", zap.String("origin", origin))

	// From here on, k.httpSrv already owns lis and is actively serving it
	// in the background goroutine above. main.go treats a Start error as
	// non-fatal and keeps running, so any error return past this point
	// MUST close k.httpSrv first — otherwise the process serves a live
	// dashboard/proxy origin for its entire remaining lifetime with no
	// plugin socket ever bound, and BaseURL keeps handing that origin to
	// clients as if the kernel were healthy.
	closeHTTP := func() { _ = k.httpSrv.Close() }

	// Unix socket: PluginHost, and nothing else. A previous core that was
	// SIGKILLed leaves the path behind, which would block the bind.
	if err := os.MkdirAll(filepath.Dir(k.cfg.SocketPath), 0o700); err != nil {
		closeHTTP()
		return fmt.Errorf("create socket dir: %w", err)
	}
	if err := os.Remove(k.cfg.SocketPath); err != nil && !os.IsNotExist(err) {
		closeHTTP()
		return fmt.Errorf("remove stale socket: %w", err)
	}
	sock, err := net.Listen("unix", k.cfg.SocketPath)
	if err != nil {
		closeHTTP()
		return fmt.Errorf("bind plugin socket: %w", err)
	}
	if err := os.Chmod(k.cfg.SocketPath, 0o600); err != nil {
		// sock hasn't been handed to grpcSrv yet on this path, so it must
		// be closed directly rather than through a server.
		_ = sock.Close()
		closeHTTP()
		return fmt.Errorf("chmod plugin socket: %w", err)
	}
	k.mu.Lock()
	k.grpcSrv = grpc.NewServer()
	k.mu.Unlock()
	pluginv1.RegisterPluginHostServer(k.grpcSrv, k.host)
	go func() {
		if err := k.grpcSrv.Serve(sock); err != nil {
			k.log.Error("plugin socket server stopped", zap.Error(err))
		}
	}()

	runCtx, cancel := context.WithCancel(ctx)

	// Publish cancel and decide whether to spawn Health/Supervisor as one
	// atomic section under k.mu. Stop() takes the same lock to mark
	// k.stopped and capture httpSrv/grpcSrv/cancel for its own cleanup —
	// so either Stop's Lock() happens-before this section (in which case
	// k.stopped is already true here, and this function tears down what
	// it just bound instead of ever calling Health.Start/Supervisor.Start)
	// or it happens-after (in which case Stop blocks until this section
	// finishes and then observes the fully-published cancel/httpSrv/
	// grpcSrv). Without this, a SIGTERM landing mid-Start could have Stop
	// capture httpSrv/grpcSrv/cancel while they were still nil, run to
	// completion having "cleaned up" nothing, and leave Health and
	// Supervisor's freshly-spawned goroutines with no one left to ever
	// cancel them — reproduced in review as a leftover socket file plus
	// permanently running plugin processes.
	k.mu.Lock()
	if k.stopped {
		k.mu.Unlock()
		cancel()
		k.grpcSrv.Stop()
		closeHTTP()
		_ = os.Remove(k.cfg.SocketPath)
		return fmt.Errorf("kernel: Stop was called while Start was still binding")
	}
	k.cancel = cancel
	k.health.Start(runCtx)
	k.sup.Start(runCtx)
	k.mu.Unlock()
	return nil
}

// Stop tears the kernel down in the order that gives plugins the best
// chance to flush: tell them, then terminate them, then close core's own
// listeners. It is idempotent and safe even if Start was never called or
// returned an error partway through — every field it touches below is
// nil-checked, and the components it always calls (BroadcastShutdown,
// Supervisor.Stop) are no-ops on a kernel that never spawned anything.
func (k *Kernel) Stop(ctx context.Context) {
	k.mu.Lock()
	if k.stopped {
		k.mu.Unlock()
		return
	}
	k.stopped = true
	httpSrv, grpcSrv, cancel := k.httpSrv, k.grpcSrv, k.cancel
	k.mu.Unlock()

	// Unblock any BaseURL caller stuck waiting on a Start that never
	// happened (or never will).
	k.closeReady()

	// BroadcastShutdown itself blocks (bounded by shutdownDrainGrace) until
	// every connected plugin's Shutdown message has actually left core, so
	// the SIGTERM sup.Stop sends next does not win a race a direct signal
	// would otherwise almost always win.
	k.host.BroadcastShutdown("core shutting down")
	k.sup.Stop(ctx)

	if cancel != nil {
		cancel()
	}
	if grpcSrv != nil {
		stopped := make(chan struct{})
		go func() { grpcSrv.GracefulStop(); close(stopped) }()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			grpcSrv.Stop()
		}
	}
	if httpSrv != nil {
		_ = httpSrv.Shutdown(ctx)
	}
	_ = os.Remove(k.cfg.SocketPath)
}
