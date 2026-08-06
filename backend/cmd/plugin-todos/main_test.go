package main

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/api"
	"github.com/vibecare-io/vibecare/backend/internal/plugins"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

const pluginID = "com.vibecare.todos"

// buildTodosPlugin compiles this package's own main.go into
// pluginDir/plugin-todos and copies manifest.yaml alongside it, giving the
// plugin registry a real, on-disk plugin directory to discover — exactly
// what `just build-todos-plugin` produces for ~/.vibecare/plugins/todos.
func buildTodosPlugin(t *testing.T, pluginDir string) {
	t.Helper()

	if err := os.MkdirAll(pluginDir, 0o755); err != nil {
		t.Fatalf("mkdir plugin dir: %v", err)
	}

	binPath := filepath.Join(pluginDir, "plugin-todos")
	cmd := exec.Command("go", "build", "-o", binPath, ".")
	// The test's own working directory is this package's directory
	// (backend/cmd/plugin-todos), which is exactly the module path "." needs.
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build plugin-todos failed: %v\n%s", err, out)
	}

	manifestSrc, err := os.ReadFile("manifest.yaml")
	if err != nil {
		t.Fatalf("read manifest.yaml: %v", err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "manifest.yaml"), manifestSrc, 0o644); err != nil {
		t.Fatalf("write manifest.yaml: %v", err)
	}
}

// startHostServer stands up a real HostService (backed by a real, migrated
// temp-file DB) on a real 127.0.0.1:0 gRPC listener, and returns its address
// plus a stop func. This is the server plugin subprocesses dial back into.
func startHostServer(t *testing.T, dbPath string) (hostAddr string, stop func()) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		t.Fatalf("mkdir db dir: %v", err)
	}

	db, err := storage.New(dbPath)
	if err != nil {
		t.Fatalf("storage.New failed: %v", err)
	}

	hub := scheduler.NewEventHub(zap.NewNop())
	hostService := plugins.NewHostService(db, hub, zap.NewNop())

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen failed: %v", err)
	}

	srv := grpc.NewServer()
	pb.RegisterHostServiceServer(srv, hostService)

	go func() { _ = srv.Serve(lis) }()

	return lis.Addr().String(), func() {
		srv.Stop()
		_ = lis.Close()
		_ = db.Close()
	}
}

// startRegistry launches a Registry (the REAL os/exec launcher — this spawns
// the actual plugin-todos subprocess and drives the real stdout handshake,
// not a test fake) against pluginDirRoot, and blocks until Start returns.
func startRegistry(t *testing.T, pluginDirRoot, hostAddr string) *plugins.Registry {
	t.Helper()

	reg := plugins.NewRegistry(pluginDirRoot, nil, hostAddr, zap.NewNop())

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := reg.Start(ctx); err != nil {
		t.Fatalf("registry.Start failed: %v", err)
	}
	return reg
}

// waitForReady polls List() until the plugin reports status "ready" (the
// registry launches and initializes plugins synchronously within Start, so
// this should already be true by the time Start returns, but polling briefly
// keeps the test robust against slow CI subprocess startup).
func waitForReady(t *testing.T, reg *plugins.Registry) plugins.PluginInfo {
	t.Helper()

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, info := range reg.List() {
			if info.ID == pluginID {
				if info.Status == "ready" {
					return info
				}
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("plugin %s never reached status ready; List()=%+v", pluginID, reg.List())
	return plugins.PluginInfo{}
}

// containsText reports whether the view tree contains a "text" node (or a
// node carrying that literal text in any field the Swift renderer would
// display) equal to want, searched recursively through Children.
func containsText(nodes []*pb.Node, want string) bool {
	for _, n := range nodes {
		if n.GetKind() == "text" && n.GetText() == want {
			return true
		}
		if containsText(n.GetChildren(), want) {
			return true
		}
	}
	return false
}

// TestTodosPluginEndToEnd is the acceptance test for the whole plugin spine:
// it builds the real todos binary, boots a real HostService, launches the
// binary as a REAL OS subprocess through Registry's production execLauncher
// (exercising the real stdout "host:port" handshake), drives it through
// PluginHostService exactly as the Swift client would (ListPlugins,
// InvokePluginAction, RenderPluginView), and finally verifies data survives
// a full registry restart against the same DB file — i.e. that plugin_data
// persistence, not just the in-memory plugin process, is real.
func TestTodosPluginEndToEnd(t *testing.T) {
	root := t.TempDir()
	pluginDirRoot := filepath.Join(root, "plugins")
	pluginDir := filepath.Join(pluginDirRoot, "todos")
	dbPath := filepath.Join(root, "db", "vibecare.db")

	buildTodosPlugin(t, pluginDir)

	hostAddr, stopHost := startHostServer(t, dbPath)
	defer stopHost()

	reg := startRegistry(t, pluginDirRoot, hostAddr)

	info := waitForReady(t, reg)
	if info.Name != "Todos" {
		t.Errorf("plugin Name = %q, want %q", info.Name, "Todos")
	}

	svc := api.NewPluginHostService(reg, zap.NewNop())
	ctx := context.Background()

	listResp, err := svc.ListPlugins(ctx, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("ListPlugins failed: %v", err)
	}
	found := false
	for _, p := range listResp.GetPlugins() {
		if p.GetId() == pluginID {
			found = true
			if p.GetStatus() != "ready" {
				t.Errorf("ListPlugins status = %q, want %q", p.GetStatus(), "ready")
			}
		}
	}
	if !found {
		t.Fatalf("ListPlugins did not include %s; got %+v", pluginID, listResp.GetPlugins())
	}

	if _, err := svc.InvokePluginAction(ctx, &pb.InvokePluginActionRequest{
		PluginId: pluginID,
		ViewId:   "main",
		Action:   "add_todo",
		Params:   map[string]string{"text": "buy milk"},
	}); err != nil {
		t.Fatalf("InvokePluginAction(add_todo) failed: %v", err)
	}

	view, err := svc.RenderPluginView(ctx, &pb.RenderPluginViewRequest{
		PluginId: pluginID,
		ViewId:   "main",
	})
	if err != nil {
		t.Fatalf("RenderPluginView failed: %v", err)
	}
	if !containsText(view.GetNodes(), "buy milk") {
		t.Fatalf("rendered view does not contain \"buy milk\": %+v", view)
	}

	// --- Persistence across a full registry restart ---
	reg.Stop()

	reg2 := startRegistry(t, pluginDirRoot, hostAddr)
	defer reg2.Stop()
	waitForReady(t, reg2)

	svc2 := api.NewPluginHostService(reg2, zap.NewNop())
	view2, err := svc2.RenderPluginView(ctx, &pb.RenderPluginViewRequest{
		PluginId: pluginID,
		ViewId:   "main",
	})
	if err != nil {
		t.Fatalf("RenderPluginView after restart failed: %v", err)
	}
	if !containsText(view2.GetNodes(), "buy milk") {
		t.Fatalf("\"buy milk\" did not survive a registry restart against the same DB: %+v", view2)
	}
}
