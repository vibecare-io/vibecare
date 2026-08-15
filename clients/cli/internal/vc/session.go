package vc

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	defaultAddr    = "127.0.0.1:50051"
	defaultWebAddr = "127.0.0.1:8080"
)

// dialTimeout bounds Dial when the caller gave a context without a deadline.
// This is a CLI: hanging on a dead backend is worse than failing.
const dialTimeout = 3 * time.Second

// streamBackoff is the first pause after the roster stream drops, doubling to
// maxBackoff. It is a var only so tests can shrink it — a user leaves the TUI
// open across a `just run` restart and it has to recover on its own, so the
// retry loop must be exercised, not stubbed.
var streamBackoff = 250 * time.Millisecond

const maxBackoff = 5 * time.Second

// httpTimeout applies to the kernel and core web requests. Both are on
// loopback, so anything slower than this is a hang, not latency.
const httpTimeout = 5 * time.Second

// Options selects the target. Both fields are host:port, both default to
// loopback: non-localhost targets are explicitly out of scope for v1.
type Options struct {
	Addr    string // gRPC, default "127.0.0.1:50051"
	WebAddr string // core HTTP, default "127.0.0.1:8080"
}

func (o Options) withDefaults() Options {
	if o.Addr == "" {
		o.Addr = defaultAddr
	}
	if o.WebAddr == "" {
		o.WebAddr = defaultWebAddr
	}
	return o
}

// Session is one connection to core: the gRPC clients, the roster stream that
// backs every plugin view, and the kernel origin learned from it.
//
// The kernel's HTTP port is ephemeral by design (it binds 127.0.0.1:0), so it
// cannot be configured or guessed. The only place it is ever published is the
// Shell.Plugins stream, which is why this type keeps that stream open for its
// whole life rather than making one call per question.
type Session struct {
	addr    string
	webAddr string

	conn     *grpc.ClientConn
	shell    clientv1.ShellClient
	schedule pb.ScheduleServiceClient
	routine  pb.RoutineServiceClient
	action   pb.ActionServiceClient

	http *http.Client

	// ctx governs the roster goroutine and every watcher; Close cancels it.
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	closed sync.Once

	mu       sync.Mutex
	roster   Roster
	token    string
	have     bool
	ready    chan struct{} // closed once the first PluginList lands
	watchers map[chan Roster]struct{}
}

// Dial connects to core and starts following the roster. It returns once the
// gRPC connection is usable; the roster arrives asynchronously, so callers
// that need the kernel origin wait for it via KernelBaseURL.
func Dial(ctx context.Context, opts Options) (*Session, error) {
	return dialWith(ctx, opts, "")
}

// dialWith is Dial with the transport injected, so the tests can run a whole
// Session over an in-process bufconn. target overrides the gRPC dial target
// while leaving Options.Addr as the name reported to humans.
func dialWith(ctx context.Context, opts Options, target string, extra ...grpc.DialOption) (*Session, error) {
	opts = opts.withDefaults()
	if target == "" {
		target = opts.Addr
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, dialTimeout)
		defer cancel()
	}

	dialOpts := append([]grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}, extra...)

	conn, err := grpc.NewClient(target, dialOpts...)
	if err != nil {
		return nil, Unreachable(opts.Addr, err)
	}
	if err := waitReady(ctx, conn); err != nil {
		_ = conn.Close()
		return nil, Unreachable(opts.Addr, err)
	}

	s := &Session{
		addr:     opts.Addr,
		webAddr:  opts.WebAddr,
		conn:     conn,
		shell:    clientv1.NewShellClient(conn),
		schedule: pb.NewScheduleServiceClient(conn),
		routine:  pb.NewRoutineServiceClient(conn),
		action:   pb.NewActionServiceClient(conn),
		// Redirects are not followed: the kernel answers a restart with a 303
		// to its HTML dashboard, and chasing that would turn a clear "it
		// worked" into a page nobody asked for.
		http: &http.Client{
			Timeout:       httpTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		done:     make(chan struct{}),
		ready:    make(chan struct{}),
		watchers: map[chan Roster]struct{}{},
	}
	// The stream outlives this call, so it gets its own context: a caller's
	// short dial deadline must not kill the connection it just opened.
	s.ctx, s.cancel = context.WithCancel(context.Background())
	go s.followRoster()

	return s, nil
}

// waitReady blocks until the connection is usable. grpc.NewClient connects
// lazily, so without this a dead backend would only surface as an error on
// the first RPC — long after `vibecare status` decided it was fine.
func waitReady(ctx context.Context, conn *grpc.ClientConn) error {
	conn.Connect()
	for {
		switch st := conn.GetState(); st {
		case connectivity.Ready:
			return nil
		case connectivity.TransientFailure:
			// Fail fast rather than retry: a CLI that hangs on a stopped
			// backend is useless, and the caller can simply run again.
			return fmt.Errorf("connection failed")
		default:
			if !conn.WaitForStateChange(ctx, st) {
				return ctx.Err()
			}
		}
	}
}

// Addr is the target as the user asked for it, for error messages.
func (s *Session) Addr() string { return s.addr }

// Close stops the roster stream and releases the connection. It is safe to
// call more than once; the TUI closes on quit and on error.
func (s *Session) Close() error {
	var err error
	s.closed.Do(func() {
		s.cancel()
		<-s.done
		err = s.conn.Close()
	})
	return err
}

// followRoster keeps one Shell.Plugins stream open for the session's life,
// reconnecting with backoff. Nothing here polls: the roster is pushed.
func (s *Session) followRoster() {
	defer close(s.done)
	defer s.closeWatchers()

	wait := streamBackoff
	for s.ctx.Err() == nil {
		delivered := s.streamRoster()
		if s.ctx.Err() != nil {
			return
		}
		if delivered {
			// A stream that worked before it dropped is a restart, not a
			// broken target, so the next attempt starts from the short pause.
			wait = streamBackoff
		}
		select {
		case <-s.ctx.Done():
			return
		case <-time.After(wait):
		}
		if wait < maxBackoff {
			wait *= 2
		}
	}
}

// streamRoster runs one stream to completion and reports whether it delivered
// anything, which is what tells the retry loop a restart from a dead target.
func (s *Session) streamRoster() bool {
	stream, err := s.shell.Plugins(s.ctx, &emptypb.Empty{})
	if err != nil {
		return false
	}
	delivered := false
	for {
		list, err := stream.Recv()
		if err != nil {
			return delivered
		}
		s.publish(list)
		delivered = true
	}
}

// publish caches the roster and hands it to every watcher. Watcher channels
// hold one snapshot each: the roster is a full list, so a slow reader wants
// the newest one, not a queue of stale ones.
func (s *Session) publish(list *clientv1.PluginList) {
	r := rosterFromStream(list)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.roster = r
	s.token = list.GetToken()
	if !s.have {
		s.have = true
		close(s.ready)
	}
	for ch := range s.watchers {
		select {
		case ch <- r:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- r:
			default:
			}
		}
	}
}

func (s *Session) closeWatchers() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.watchers {
		delete(s.watchers, ch)
		close(ch)
	}
}

// awaitRoster returns the cached roster, blocking until the first one arrives.
// A context that expires first means core is answering gRPC but never sent a
// roster, which for every caller here is indistinguishable from unreachable.
func (s *Session) awaitRoster(ctx context.Context) (Roster, error) {
	s.mu.Lock()
	if s.have {
		r := s.roster
		s.mu.Unlock()
		return r, nil
	}
	s.mu.Unlock()

	select {
	case <-s.ready:
	case <-s.ctx.Done():
		return Roster{}, Errorf("session closed")
	case <-ctx.Done():
		return Roster{}, Unreachable(s.addr, fmt.Errorf("no plugin roster received: %w", ctx.Err()))
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	return s.roster, nil
}

// KernelBaseURL is the origin of the kernel's HTTP surface, learned from the
// roster stream. It blocks until the first roster arrives because there is no
// other way to know it — the port is ephemeral.
func (s *Session) KernelBaseURL(ctx context.Context) (string, error) {
	r, err := s.awaitRoster(ctx)
	if err != nil {
		return "", err
	}
	if r.BaseURL == "" {
		return "", Errorf("core reported no kernel origin")
	}
	return r.BaseURL, nil
}

// kernelOrigin returns the base URL and session token together, since every
// kernel request needs both.
func (s *Session) kernelOrigin(ctx context.Context) (string, string, error) {
	base, err := s.KernelBaseURL(ctx)
	if err != nil {
		return "", "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return base, s.token, nil
}
