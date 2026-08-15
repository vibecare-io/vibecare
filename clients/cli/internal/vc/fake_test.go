package vc

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/types/known/emptypb"
)

// This file is the whole test harness for package vc: an in-process gRPC
// server over bufconn plus two httptest servers standing in for the kernel's
// ephemeral HTTP surface and core's web server. Every test in this package
// runs against it, so nothing here may touch a real backend, database or
// plugin.
//
// All four services are registered even though only Shell is exercised
// below — the domain wrappers (schedules, routines, actions) are programmed
// through the same fakes, and a service that isn't registered fails with
// Unimplemented in a way that looks like a client bug.

const testToken = "test-session-token"

// fakes is the programmable half of the harness. A test reaches in, sets a
// response, and calls the Session method under test.
type fakes struct {
	shell     *fakeShell
	schedules *fakeSchedules
	routines  *fakeRoutines
	actions   *fakeActions

	kernel *kernelStub
	web    *webStub
}

type testConfig struct {
	kernelDown  bool
	webDown     bool
	silentShell bool
	plugins     []kernelPlugin
	roster      []*clientv1.PluginInfo
}

type testOpt func(*testConfig)

// withoutKernel points base_url at a listener that has already been closed,
// which is what a kernel that failed to start looks like from here.
func withoutKernel() testOpt { return func(c *testConfig) { c.kernelDown = true } }

// withoutWeb kills core's HTTP server while leaving gRPC up — a real,
// observed state that `vibecare status` has to render rather than reject.
func withoutWeb() testOpt { return func(c *testConfig) { c.webDown = true } }

// withSilentShell accepts the Plugins stream but never sends a PluginList,
// which is the only way to exercise "kernel origin not yet known".
func withSilentShell() testOpt { return func(c *testConfig) { c.silentShell = true } }

// withKernelPlugins sets what GET /_core/api/plugins returns.
func withKernelPlugins(ps ...kernelPlugin) testOpt {
	return func(c *testConfig) { c.plugins = ps }
}

// withRoster sets what the Shell stream sends. It is independent of
// withKernelPlugins on purpose: the two surfaces disagreeing is the case
// worth testing.
func withRoster(ps ...*clientv1.PluginInfo) testOpt {
	return func(c *testConfig) { c.roster = ps }
}

func newTestServer(t *testing.T, opts ...testOpt) (*Session, *fakes) {
	t.Helper()

	cfg := testConfig{
		plugins: []kernelPlugin{{
			ID: "todo", Name: "Todo", Path: "/p/todo/", UI: "html",
			LogPath: "/tmp/vibecare-test/logs/plugins/todo.log",
			State:   "up", PID: 4242, UptimeSec: 90, Restarts: 1,
			ProbeLatencyMS: 3, EventsPublished: 7, EventsDelivered: 5,
		}},
		roster: []*clientv1.PluginInfo{{
			Id: "todo", Name: "Todo", Icon: "checkmark", Path: "/p/todo/",
			State: clientv1.State_UP,
		}},
	}
	for _, o := range opts {
		o(&cfg)
	}

	f := &fakes{
		shell:     newFakeShell(cfg.silentShell),
		schedules: &fakeSchedules{},
		routines:  &fakeRoutines{},
		actions:   &fakeActions{},
		kernel:    newKernelStub(t, cfg.plugins, cfg.kernelDown),
		web:       newWebStub(t, cfg.webDown),
	}

	f.shell.set(&clientv1.PluginList{
		Plugins: cfg.roster,
		BaseUrl: f.kernel.URL,
		Token:   testToken,
	})

	lis := bufconn.Listen(1 << 20)
	srv := grpc.NewServer()
	clientv1.RegisterShellServer(srv, f.shell)
	pb.RegisterScheduleServiceServer(srv, f.schedules)
	pb.RegisterRoutineServiceServer(srv, f.routines)
	pb.RegisterActionServiceServer(srv, f.actions)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// "passthrough:///" because grpc.NewClient defaults to the dns resolver,
	// which would try to resolve the bufconn target name for real.
	sess, err := dialWith(ctx, Options{Addr: "bufnet", WebAddr: f.web.addr()},
		"passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return lis.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatalf("dial test server: %v", err)
	}
	t.Cleanup(func() { _ = sess.Close() })

	return sess, f
}

// --- Shell -----------------------------------------------------------------

type fakeShell struct {
	clientv1.UnimplementedShellServer

	mu       sync.Mutex
	list     *clientv1.PluginList
	silent   bool
	failures int // number of upcoming Plugins calls that fail immediately
	connects int
	rosters  map[*rosterSub]struct{}
	intents  map[*intentSub]struct{}
}

// A subscription carries a kill channel as well as its updates so a test can
// drop a live stream the way a core restart does.
type rosterSub struct {
	ch   chan *clientv1.PluginList
	kill chan struct{}
}

type intentSub struct {
	ch   chan *clientv1.UIIntent
	kill chan struct{}
}

func newFakeShell(silent bool) *fakeShell {
	return &fakeShell{
		silent:  silent,
		rosters: map[*rosterSub]struct{}{},
		intents: map[*intentSub]struct{}{},
	}
}

func (f *fakeShell) set(l *clientv1.PluginList) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.list = l
}

// push replaces the roster and delivers it to every connected stream.
func (f *fakeShell) push(l *clientv1.PluginList) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.list = l
	for s := range f.rosters {
		select {
		case s.ch <- l:
		default:
		}
	}
}

func (f *fakeShell) pushAlert(a *clientv1.Alert) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for s := range f.intents {
		select {
		case s.ch <- &clientv1.UIIntent{K: &clientv1.UIIntent_Alert{Alert: a}}:
		default:
		}
	}
}

// dropAll ends every live stream, which is what a core restart looks like to
// a client that stayed open across it.
func (f *fakeShell) dropAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for s := range f.rosters {
		close(s.kill)
		delete(f.rosters, s)
	}
	for s := range f.intents {
		close(s.kill)
		delete(f.intents, s)
	}
}

// failNext makes the next n Plugins calls fail, so a test can watch the
// session reconnect.
func (f *fakeShell) failNext(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failures = n
}

// talk undoes withSilentShell mid-test.
func (f *fakeShell) talk() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.silent = false
}

func (f *fakeShell) connectCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.connects
}

func (f *fakeShell) Plugins(_ *emptypb.Empty, stream clientv1.Shell_PluginsServer) error {
	f.mu.Lock()
	f.connects++
	if f.failures > 0 {
		f.failures--
		f.mu.Unlock()
		return status.Error(codes.Unavailable, "fake shell is down")
	}
	first, silent := f.list, f.silent
	sub := &rosterSub{ch: make(chan *clientv1.PluginList, 8), kill: make(chan struct{})}
	f.rosters[sub] = struct{}{}
	f.mu.Unlock()

	defer func() {
		f.mu.Lock()
		delete(f.rosters, sub)
		f.mu.Unlock()
	}()

	if first != nil && !silent {
		if err := stream.Send(first); err != nil {
			return err
		}
	}
	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-sub.kill:
			return status.Error(codes.Unavailable, "fake shell dropped the stream")
		case l := <-sub.ch:
			if err := stream.Send(l); err != nil {
				return err
			}
		}
	}
}

func (f *fakeShell) Intents(_ *emptypb.Empty, stream clientv1.Shell_IntentsServer) error {
	sub := &intentSub{ch: make(chan *clientv1.UIIntent, 8), kill: make(chan struct{})}
	f.mu.Lock()
	f.intents[sub] = struct{}{}
	f.mu.Unlock()

	defer func() {
		f.mu.Lock()
		delete(f.intents, sub)
		f.mu.Unlock()
	}()

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-sub.kill:
			return status.Error(codes.Unavailable, "fake shell dropped the stream")
		case i := <-sub.ch:
			if err := stream.Send(i); err != nil {
				return err
			}
		}
	}
}

// --- kernel HTTP -----------------------------------------------------------

type kernelStub struct {
	*httptest.Server

	mu       sync.Mutex
	plugins  []kernelPlugin
	restarts []string
}

func newKernelStub(t *testing.T, plugins []kernelPlugin, down bool) *kernelStub {
	t.Helper()
	k := &kernelStub{plugins: plugins}

	mux := http.NewServeMux()
	mux.HandleFunc("/_core/api/plugins", func(w http.ResponseWriter, r *http.Request) {
		if !k.authorized(r) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		k.mu.Lock()
		body := kernelStatus{Plugins: append([]kernelPlugin(nil), k.plugins...)}
		k.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	})
	mux.HandleFunc("/_core/api/plugins/", func(w http.ResponseWriter, r *http.Request) {
		if !k.authorized(r) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, "/_core/api/plugins/")
		id, action, ok := strings.Cut(rest, "/")
		if !ok || action != "restart" || !k.known(id) {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		k.mu.Lock()
		k.restarts = append(k.restarts, id)
		k.mu.Unlock()
		http.Redirect(w, r, "/_core/status", http.StatusSeeOther)
	})

	k.Server = httptest.NewServer(mux)
	if down {
		k.Server.Close() // URL now points at a closed port
	} else {
		t.Cleanup(k.Server.Close)
	}
	return k
}

// authorized mirrors kernel.Auth: the session cookie, or the one-time ?vc=
// handoff. Anything else is a 401, so a client that guesses a header name
// fails here rather than in production.
func (k *kernelStub) authorized(r *http.Request) bool {
	if r.URL.Query().Get("vc") == testToken {
		return true
	}
	c, err := r.Cookie("vc_session")
	return err == nil && c.Value == testToken
}

func (k *kernelStub) known(id string) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	for _, p := range k.plugins {
		if p.ID == id {
			return true
		}
	}
	return false
}

func (k *kernelStub) setPlugins(ps ...kernelPlugin) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.plugins = ps
}

func (k *kernelStub) restarted() []string {
	k.mu.Lock()
	defer k.mu.Unlock()
	return append([]string(nil), k.restarts...)
}

// --- core web --------------------------------------------------------------

type webStub struct {
	*httptest.Server

	mu        sync.Mutex
	version   string
	scheduler map[string]any
}

func newWebStub(t *testing.T, down bool) *webStub {
	t.Helper()
	w := &webStub{
		version: "1.2.3",
		scheduler: map[string]any{
			"stats":      map[string]any{"total": float64(3), "active": float64(2), "paused": float64(1)},
			"schedules":  []any{},
			"updated_at": "2026-08-14T00:00:00Z",
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/version", func(rw http.ResponseWriter, _ *http.Request) {
		w.mu.Lock()
		v := w.version
		w.mu.Unlock()
		rw.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(rw).Encode(map[string]string{"version": v})
	})
	mux.HandleFunc("/api/scheduler/status", func(rw http.ResponseWriter, _ *http.Request) {
		w.mu.Lock()
		s := w.scheduler
		w.mu.Unlock()
		if s == nil {
			http.Error(rw, "scheduler unavailable", http.StatusInternalServerError)
			return
		}
		rw.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(rw).Encode(s)
	})

	w.Server = httptest.NewServer(mux)
	if down {
		w.Server.Close()
	} else {
		t.Cleanup(w.Server.Close)
	}
	return w
}

// addr is what Options.WebAddr wants: host:port, no scheme.
func (w *webStub) addr() string { return strings.TrimPrefix(w.Server.URL, "http://") }

func (w *webStub) setScheduler(s map[string]any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.scheduler = s
}

// --- domain services -------------------------------------------------------
//
// Every method is a nil-able function field: unset means Unimplemented, which
// is exactly what a caller would see from a core that predates the RPC.

func unset(rpc string) error {
	return status.Errorf(codes.Unimplemented, "fake: %s not programmed", rpc)
}

type fakeSchedules struct {
	pb.UnimplementedScheduleServiceServer

	listFn       func(context.Context, *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error)
	getFn        func(context.Context, *pb.GetScheduleRequest) (*pb.Schedule, error)
	pauseFn      func(context.Context, *pb.PauseScheduleRequest) (*pb.Schedule, error)
	resumeFn     func(context.Context, *pb.ResumeScheduleRequest) (*pb.Schedule, error)
	pauseAllFn   func(context.Context, *pb.PauseAllSchedulesRequest) (*emptypb.Empty, error)
	resumeAllFn  func(context.Context, *pb.ResumeAllSchedulesRequest) (*emptypb.Empty, error)
	actionsFn    func(context.Context, *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error)
	lastListReq  *pb.ListSchedulesRequest
	lastGetReqID string
}

func (f *fakeSchedules) ListSchedules(ctx context.Context, r *pb.ListSchedulesRequest) (*pb.ListSchedulesResponse, error) {
	f.lastListReq = r
	if f.listFn == nil {
		return nil, unset("ListSchedules")
	}
	return f.listFn(ctx, r)
}

func (f *fakeSchedules) GetSchedule(ctx context.Context, r *pb.GetScheduleRequest) (*pb.Schedule, error) {
	f.lastGetReqID = r.GetScheduleId()
	if f.getFn == nil {
		return nil, unset("GetSchedule")
	}
	return f.getFn(ctx, r)
}

func (f *fakeSchedules) PauseSchedule(ctx context.Context, r *pb.PauseScheduleRequest) (*pb.Schedule, error) {
	if f.pauseFn == nil {
		return nil, unset("PauseSchedule")
	}
	return f.pauseFn(ctx, r)
}

func (f *fakeSchedules) ResumeSchedule(ctx context.Context, r *pb.ResumeScheduleRequest) (*pb.Schedule, error) {
	if f.resumeFn == nil {
		return nil, unset("ResumeSchedule")
	}
	return f.resumeFn(ctx, r)
}

func (f *fakeSchedules) PauseAllSchedules(ctx context.Context, r *pb.PauseAllSchedulesRequest) (*emptypb.Empty, error) {
	if f.pauseAllFn == nil {
		return nil, unset("PauseAllSchedules")
	}
	return f.pauseAllFn(ctx, r)
}

func (f *fakeSchedules) ResumeAllSchedules(ctx context.Context, r *pb.ResumeAllSchedulesRequest) (*emptypb.Empty, error) {
	if f.resumeAllFn == nil {
		return nil, unset("ResumeAllSchedules")
	}
	return f.resumeAllFn(ctx, r)
}

func (f *fakeSchedules) GetScheduleActions(ctx context.Context, r *pb.GetScheduleActionsRequest) (*pb.GetScheduleActionsResponse, error) {
	if f.actionsFn == nil {
		return nil, unset("GetScheduleActions")
	}
	return f.actionsFn(ctx, r)
}

type fakeRoutines struct {
	pb.UnimplementedRoutineServiceServer

	listFn    func(context.Context, *pb.ListRoutinesRequest) (*pb.ListRoutinesResponse, error)
	getFn     func(context.Context, *pb.GetRoutineRequest) (*pb.GetRoutineResponse, error)
	executeFn func(context.Context, *pb.ExecuteRoutineRequest) (*pb.ExecutionLog, error)
	logsFn    func(context.Context, *pb.GetExecutionLogsRequest) (*pb.GetExecutionLogsResponse, error)
}

func (f *fakeRoutines) ListRoutines(ctx context.Context, r *pb.ListRoutinesRequest) (*pb.ListRoutinesResponse, error) {
	if f.listFn == nil {
		return nil, unset("ListRoutines")
	}
	return f.listFn(ctx, r)
}

func (f *fakeRoutines) GetRoutine(ctx context.Context, r *pb.GetRoutineRequest) (*pb.GetRoutineResponse, error) {
	if f.getFn == nil {
		return nil, unset("GetRoutine")
	}
	return f.getFn(ctx, r)
}

func (f *fakeRoutines) ExecuteRoutine(ctx context.Context, r *pb.ExecuteRoutineRequest) (*pb.ExecutionLog, error) {
	if f.executeFn == nil {
		return nil, unset("ExecuteRoutine")
	}
	return f.executeFn(ctx, r)
}

func (f *fakeRoutines) GetExecutionLogs(ctx context.Context, r *pb.GetExecutionLogsRequest) (*pb.GetExecutionLogsResponse, error) {
	if f.logsFn == nil {
		return nil, unset("GetExecutionLogs")
	}
	return f.logsFn(ctx, r)
}

type fakeActions struct {
	pb.UnimplementedActionServiceServer

	listFn    func(context.Context, *pb.ListActionsRequest) (*pb.ListActionsResponse, error)
	getFn     func(context.Context, *pb.GetActionRequest) (*pb.Action, error)
	executeFn func(context.Context, *pb.ExecuteActionRequest) (*pb.ExecuteActionResponse, error)
	typesFn   func(context.Context, *pb.ListActionTypesRequest) (*pb.ListActionTypesResponse, error)
}

func (f *fakeActions) ListActions(ctx context.Context, r *pb.ListActionsRequest) (*pb.ListActionsResponse, error) {
	if f.listFn == nil {
		return nil, unset("ListActions")
	}
	return f.listFn(ctx, r)
}

func (f *fakeActions) GetAction(ctx context.Context, r *pb.GetActionRequest) (*pb.Action, error) {
	if f.getFn == nil {
		return nil, unset("GetAction")
	}
	return f.getFn(ctx, r)
}

func (f *fakeActions) ExecuteAction(ctx context.Context, r *pb.ExecuteActionRequest) (*pb.ExecuteActionResponse, error) {
	if f.executeFn == nil {
		return nil, unset("ExecuteAction")
	}
	return f.executeFn(ctx, r)
}

func (f *fakeActions) ListActionTypes(ctx context.Context, r *pb.ListActionTypesRequest) (*pb.ListActionTypesResponse, error) {
	if f.typesFn == nil {
		return nil, unset("ListActionTypes")
	}
	return f.typesFn(ctx, r)
}

// testCtx bounds every test's calls so a hung stream fails the test instead
// of the whole package timing out.
func testCtx(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}
