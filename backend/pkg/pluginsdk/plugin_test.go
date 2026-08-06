package pluginsdk

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakeHostServer is a minimal in-process pb.HostServiceServer standing in
// for Core during tests. It's a hand-rolled fake rather than
// backend/internal/plugins.HostService (which needs a real *storage.DB and
// *scheduler.EventHub) because pluginsdk only needs to observe that
// StoreData was called with the right value — pulling in Core's storage
// layer just to assert that would be more setup than the test needs.
type fakeHostServer struct {
	pb.UnimplementedHostServiceServer

	mu    sync.Mutex
	store map[string]map[string]string // collection -> key -> value_json
}

func newFakeHostServer() *fakeHostServer {
	return &fakeHostServer{store: make(map[string]map[string]string)}
}

func (f *fakeHostServer) StoreData(_ context.Context, req *pb.StoreRequest) (*emptypb.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.store[req.GetCollection()] == nil {
		f.store[req.GetCollection()] = make(map[string]string)
	}
	f.store[req.GetCollection()][req.GetKey()] = req.GetValueJson()
	return &emptypb.Empty{}, nil
}

func (f *fakeHostServer) QueryData(_ context.Context, req *pb.QueryRequest) (*pb.QueryResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var records []*pb.Record
	for k, v := range f.store[req.GetCollection()] {
		records = append(records, &pb.Record{Key: k, ValueJson: v})
	}
	return &pb.QueryResponse{Records: records}, nil
}

func (f *fakeHostServer) DeleteData(_ context.Context, req *pb.DeleteRequest) (*emptypb.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.store[req.GetCollection()], req.GetKey())
	return &emptypb.Empty{}, nil
}

func (f *fakeHostServer) get(collection, key string) (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	v, ok := f.store[collection][key]
	return v, ok
}

// startFakeHost starts fakeHostServer on an ephemeral localhost port and
// returns its address plus a stop func.
func startFakeHost(t *testing.T) (addr string, host *fakeHostServer, stop func()) {
	t.Helper()

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen failed: %v", err)
	}

	srv := grpc.NewServer()
	h := newFakeHostServer()
	pb.RegisterHostServiceServer(srv, h)

	go func() { _ = srv.Serve(lis) }()

	return lis.Addr().String(), h, func() {
		srv.Stop()
		_ = lis.Close()
	}
}

// dialPlugin connects a pb.PluginServiceClient to addr, registering cleanup.
func dialPlugin(t *testing.T, addr string) pb.PluginServiceClient {
	t.Helper()
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial plugin failed: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return pb.NewPluginServiceClient(conn)
}

// TestPluginServesManifestRenderAndAction exercises the full loop: register
// an OnRender + OnAction handler, start the plugin via the start() seam
// (bypassing Run()'s stdout print + flag parsing), then drive it as Core
// would: GetManifest, HealthCheck, RenderView, InvokeAction (whole-view
// refresh) and ExecuteAction (fire-and-forget dispatch), asserting the
// action handler's store write reached the fake host.
func TestPluginServesManifestRenderAndAction(t *testing.T) {
	hostAddr, host, stopHost := startFakeHost(t)
	t.Cleanup(stopHost)

	p := newPlugin(fileManifest{
		ID:      "com.vibecare.todos",
		Name:    "Todos",
		Version: "0.1.0",
	})
	p.manifest.Provides.Actions = []string{"add"}
	p.manifest.UI.Kind = "shell-native"
	p.manifest.UI.Entry = "main"

	p.OnRender("main", func(ctx Ctx) View {
		return List(Row(Text("hello")))
	})
	p.OnAction("add", func(ctx Ctx, params map[string]string) error {
		return ctx.Host.Store("items", params["id"], map[string]string{"name": params["name"]})
	})

	addr, stop, err := p.start(hostAddr)
	if err != nil {
		t.Fatalf("start failed: %v", err)
	}
	t.Cleanup(stop)

	client := dialPlugin(t, addr)
	ctx := context.Background()

	// GetManifest
	manifest, err := client.GetManifest(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("GetManifest failed: %v", err)
	}
	if manifest.GetId() != "com.vibecare.todos" || manifest.GetName() != "Todos" {
		t.Errorf("GetManifest = %+v, want id/name com.vibecare.todos/Todos", manifest)
	}
	if len(manifest.GetActions()) != 1 || manifest.GetActions()[0] != "add" {
		t.Errorf("GetManifest.Actions = %v, want [add]", manifest.GetActions())
	}

	// HealthCheck
	health, err := client.HealthCheck(ctx, &emptypb.Empty{})
	if err != nil || !health.GetOk() {
		t.Fatalf("HealthCheck = %+v, err=%v, want ok=true", health, err)
	}

	// RenderView
	view, err := client.RenderView(ctx, &pb.RenderViewRequest{ViewId: "main"})
	if err != nil {
		t.Fatalf("RenderView failed: %v", err)
	}
	if len(view.GetNodes()) != 1 || view.GetNodes()[0].GetKind() != "list" {
		t.Fatalf("RenderView = %+v, want single root list node", view)
	}

	// InvokeAction: dispatches to OnAction, then re-renders "main" for the
	// whole-view-refresh response.
	invokeResp, err := client.InvokeAction(ctx, &pb.InvokeActionRequest{
		ViewId: "main",
		Action: "add",
		Params: map[string]string{"id": "1", "name": "milk"},
	})
	if err != nil {
		t.Fatalf("InvokeAction failed: %v", err)
	}
	if invokeResp.GetView() == nil || len(invokeResp.GetView().GetNodes()) != 1 || invokeResp.GetView().GetNodes()[0].GetKind() != "list" {
		t.Fatalf("InvokeAction response view = %+v, want re-rendered list", invokeResp.GetView())
	}

	stored, ok := host.get("items", "1")
	if !ok {
		t.Fatal("expected OnAction's ctx.Host.Store to reach the fake host under collection=items key=1")
	}
	if !strings.Contains(stored, "milk") {
		t.Errorf("stored value = %q, want it to contain %q", stored, "milk")
	}

	// ExecuteAction: fire-and-forget dispatch (no re-render).
	execResp, err := client.ExecuteAction(ctx, &pb.PluginExecuteActionRequest{
		Action: "add",
		Params: map[string]string{"id": "2", "name": "eggs"},
	})
	if err != nil {
		t.Fatalf("ExecuteAction failed: %v", err)
	}
	if !execResp.GetOk() {
		t.Errorf("ExecuteAction.Ok = false, message=%q, want true", execResp.GetMessage())
	}
	if _, ok := host.get("items", "2"); !ok {
		t.Fatal("expected ExecuteAction's OnAction call to reach the fake host under collection=items key=2")
	}
}

// TestHostClientDeleteRemovesRecord verifies ctx.Host.Delete reaches the
// host's DeleteData RPC and removes a previously stored record.
func TestHostClientDeleteRemovesRecord(t *testing.T) {
	hostAddr, host, stopHost := startFakeHost(t)
	t.Cleanup(stopHost)

	p := newPlugin(fileManifest{ID: "com.vibecare.todos"})
	p.OnAction("add", func(ctx Ctx, params map[string]string) error {
		return ctx.Host.Store("items", params["id"], map[string]string{"name": params["name"]})
	})
	p.OnAction("remove", func(ctx Ctx, params map[string]string) error {
		return ctx.Host.Delete("items", params["id"])
	})
	p.OnRender("main", func(ctx Ctx) View { return List() })

	addr, stop, err := p.start(hostAddr)
	if err != nil {
		t.Fatalf("start failed: %v", err)
	}
	t.Cleanup(stop)

	client := dialPlugin(t, addr)
	ctx := context.Background()

	if _, err := client.InvokeAction(ctx, &pb.InvokeActionRequest{
		ViewId: "main", Action: "add", Params: map[string]string{"id": "1", "name": "milk"},
	}); err != nil {
		t.Fatalf("InvokeAction(add) failed: %v", err)
	}
	if _, ok := host.get("items", "1"); !ok {
		t.Fatal("expected item to be stored before delete")
	}

	if _, err := client.InvokeAction(ctx, &pb.InvokeActionRequest{
		ViewId: "main", Action: "remove", Params: map[string]string{"id": "1"},
	}); err != nil {
		t.Fatalf("InvokeAction(remove) failed: %v", err)
	}

	if _, ok := host.get("items", "1"); ok {
		t.Fatal("expected ctx.Host.Delete to remove the item from the fake host")
	}
}

// TestPluginExecuteActionUnknownReturnsNotOk verifies that dispatching to a
// name with no registered OnAction handler fails soft (ok=false) rather than
// erroring the RPC.
func TestPluginExecuteActionUnknownReturnsNotOk(t *testing.T) {
	hostAddr, _, stopHost := startFakeHost(t)
	t.Cleanup(stopHost)

	p := newPlugin(fileManifest{ID: "com.vibecare.todos"})
	addr, stop, err := p.start(hostAddr)
	if err != nil {
		t.Fatalf("start failed: %v", err)
	}
	t.Cleanup(stop)

	client := dialPlugin(t, addr)
	resp, err := client.ExecuteAction(context.Background(), &pb.PluginExecuteActionRequest{Action: "nope"})
	if err != nil {
		t.Fatalf("ExecuteAction failed: %v", err)
	}
	if resp.GetOk() {
		t.Error("ExecuteAction.Ok = true for unknown action, want false")
	}
}

// TestPluginStartWithoutHostAddrLeavesHostNil verifies the standalone-run
// case (no --host) doesn't fail to start — Ctx.Host is simply nil for any
// handler that gets invoked, which is fine since tests (and Core) always
// pass a host address in practice.
func TestPluginStartWithoutHostAddrLeavesHostNil(t *testing.T) {
	p := newPlugin(fileManifest{ID: "com.vibecare.todos"})
	addr, stop, err := p.start("")
	if err != nil {
		t.Fatalf("start with empty host addr failed: %v", err)
	}
	t.Cleanup(stop)
	if addr == "" {
		t.Error("start() returned empty addr")
	}
	if p.host != nil {
		t.Error("expected p.host to be nil when no --host was given")
	}
}
