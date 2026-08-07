package plugins

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

// stubPluginServer is a minimal in-process pb.PluginServiceServer used to
// test Registry without spawning real OS subprocesses.
type stubPluginServer struct {
	pb.UnimplementedPluginServiceServer
	manifest *pb.Manifest
}

func (s *stubPluginServer) GetManifest(_ context.Context, _ *emptypb.Empty) (*pb.Manifest, error) {
	return s.manifest, nil
}

func (s *stubPluginServer) Initialize(_ context.Context, _ *pb.InitRequest) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

func (s *stubPluginServer) HealthCheck(_ context.Context, _ *emptypb.Empty) (*pb.Health, error) {
	return &pb.Health{Ok: true}, nil
}

func (s *stubPluginServer) RenderView(_ context.Context, _ *pb.RenderViewRequest) (*pb.ViewDescriptor, error) {
	return &pb.ViewDescriptor{}, nil
}

// startStubPlugin starts a real localhost gRPC server hosting a
// stubPluginServer and returns its address plus a stop func. This stands in
// for a plugin subprocess in tests.
func startStubPlugin(t *testing.T, id string) (addr string, stop func()) {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen failed: %v", err)
	}

	srv := grpc.NewServer()
	pb.RegisterPluginServiceServer(srv, &stubPluginServer{
		manifest: &pb.Manifest{Id: id, Name: "Stub " + id},
	})

	go func() { _ = srv.Serve(lis) }()

	return lis.Addr().String(), func() {
		srv.Stop()
		_ = lis.Close()
	}
}

// fakeLauncher is a test launcher injected in place of the production
// os/exec launcher. It ignores the manifest's exec field and instead hands
// back the address of a pre-registered in-process stub server for a given
// plugin id — this is the seam that lets Registry tests avoid real
// subprocesses.
type fakeLauncher struct {
	addrs map[string]string // plugin id -> addr
	stops map[string]func() // plugin id -> stop func
	fail  map[string]bool   // plugin id -> force launch failure

	mu    sync.Mutex
	calls map[string]int // plugin id -> number of times launch() was called
}

func (f *fakeLauncher) launch(_ context.Context, _ string, m FileManifest, _ string) (string, func(), error) {
	f.mu.Lock()
	if f.calls == nil {
		f.calls = make(map[string]int)
	}
	f.calls[m.ID]++
	f.mu.Unlock()

	if f.fail[m.ID] {
		return "", nil, fmt.Errorf("forced launch failure for %s", m.ID)
	}
	addr, ok := f.addrs[m.ID]
	if !ok {
		return "", nil, fmt.Errorf("no stub registered for %s", m.ID)
	}
	return addr, f.stops[m.ID], nil
}

// callCount returns how many times launch() was invoked for a given plugin
// id — used to assert a rejected duplicate was never launched.
func (f *fakeLauncher) callCount(id string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[id]
}

// writeManifest writes a manifest.yaml for a plugin under dir, creating dir
// if needed.
func writeManifest(t *testing.T, dir, id, name, exec string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("MkdirAll failed: %v", err)
	}
	content := fmt.Sprintf(`
id: %s
name: %s
version: 0.1.0
icon: checklist
exec: %s
provides:
  actions: []
  events: []
  data: []
ui:
  kind: shell-native
  entry: main
`, id, name, exec)
	path := filepath.Join(dir, "manifest.yaml")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
}

// TestRegistryStartLoadsReadyPlugin verifies that Start() discovers a
// manifest, launches it (via the injected fake launcher), calls
// GetManifest+Initialize, and records it as "ready" with a working client.
func TestRegistryStartLoadsReadyPlugin(t *testing.T) {
	root := t.TempDir()
	pluginDir := filepath.Join(root, "todos")
	writeManifest(t, pluginDir, "com.vibecare.todos", "Todos", "./todos")

	addr, stop := startStubPlugin(t, "com.vibecare.todos")
	t.Cleanup(stop)

	fl := &fakeLauncher{
		addrs: map[string]string{"com.vibecare.todos": addr},
		stops: map[string]func(){"com.vibecare.todos": func() {}},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)
	t.Cleanup(reg.Stop)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	list := reg.List()
	if len(list) != 1 {
		t.Fatalf("List() = %+v, want 1 plugin", list)
	}
	if list[0].ID != "com.vibecare.todos" || list[0].Status != "ready" {
		t.Errorf("unexpected plugin info: %+v", list[0])
	}
	if list[0].Name != "Todos" || list[0].UIKind != "shell-native" || list[0].UIEntry != "main" {
		t.Errorf("unexpected plugin info fields: %+v", list[0])
	}

	client, ok := reg.Client("com.vibecare.todos")
	if !ok {
		t.Fatal("Client() not found for com.vibecare.todos")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	health, err := client.HealthCheck(ctx, &emptypb.Empty{})
	if err != nil || !health.GetOk() {
		t.Errorf("HealthCheck failed: ok=%v err=%v", health.GetOk(), err)
	}

	manifest, err := client.GetManifest(ctx, &emptypb.Empty{})
	if err != nil || manifest.GetId() != "com.vibecare.todos" {
		t.Errorf("GetManifest failed: %+v err=%v", manifest, err)
	}
}

// TestRegistryStartSkipsBadPluginButLoadsGoodOne verifies that a manifest
// missing a required field (exec) is skipped without preventing a sibling
// good plugin from loading.
func TestRegistryStartSkipsBadPluginButLoadsGoodOne(t *testing.T) {
	root := t.TempDir()

	goodDir := filepath.Join(root, "todos")
	writeManifest(t, goodDir, "com.vibecare.todos", "Todos", "./todos")

	badDir := filepath.Join(root, "broken")
	writeManifest(t, badDir, "com.vibecare.broken", "Broken", "") // missing exec

	goodAddr, goodStop := startStubPlugin(t, "com.vibecare.todos")
	t.Cleanup(goodStop)

	fl := &fakeLauncher{
		addrs: map[string]string{"com.vibecare.todos": goodAddr},
		stops: map[string]func(){"com.vibecare.todos": func() {}},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)
	t.Cleanup(reg.Stop)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	list := reg.List()
	if len(list) != 1 {
		t.Fatalf("List() = %+v, want exactly 1 ready plugin (bad one skipped)", list)
	}
	if list[0].ID != "com.vibecare.todos" {
		t.Errorf("unexpected plugin loaded: %+v", list[0])
	}

	if _, ok := reg.Client("com.vibecare.broken"); ok {
		t.Error("Client() should not find the broken plugin")
	}
}

// TestRegistryStartSkipsPluginWhenLaunchFails verifies that a launcher
// failure (e.g. dial failure) for one plugin does not abort loading others.
func TestRegistryStartSkipsPluginWhenLaunchFails(t *testing.T) {
	root := t.TempDir()

	goodDir := filepath.Join(root, "todos")
	writeManifest(t, goodDir, "com.vibecare.todos", "Todos", "./todos")

	failDir := filepath.Join(root, "flaky")
	writeManifest(t, failDir, "com.vibecare.flaky", "Flaky", "./flaky")

	goodAddr, goodStop := startStubPlugin(t, "com.vibecare.todos")
	t.Cleanup(goodStop)

	fl := &fakeLauncher{
		addrs: map[string]string{"com.vibecare.todos": goodAddr},
		stops: map[string]func(){"com.vibecare.todos": func() {}},
		fail:  map[string]bool{"com.vibecare.flaky": true},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)
	t.Cleanup(reg.Stop)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	list := reg.List()
	if len(list) != 1 || list[0].ID != "com.vibecare.todos" {
		t.Fatalf("expected only the good plugin loaded, got %+v", list)
	}
}

// TestRegistryStartSkipsDuplicatePluginID verifies that when two manifests
// (in different directories) declare the same plugin id, only the first one
// discovered is loaded. The duplicate must be rejected BEFORE it is ever
// launched — not launched-then-dropped — so nothing leaks a subprocess or
// connection that Stop() would otherwise never find (since the second
// loadOne would have overwritten the first in the id-keyed map).
func TestRegistryStartSkipsDuplicatePluginID(t *testing.T) {
	root := t.TempDir()

	// os.ReadDir returns entries in sorted order, so "dup-a" is discovered
	// (and loaded) before "dup-b".
	dirA := filepath.Join(root, "dup-a")
	writeManifest(t, dirA, "com.vibecare.dup", "Dup A", "./dup")

	dirB := filepath.Join(root, "dup-b")
	writeManifest(t, dirB, "com.vibecare.dup", "Dup B", "./dup")

	addr, stop := startStubPlugin(t, "com.vibecare.dup")
	t.Cleanup(stop)

	fl := &fakeLauncher{
		addrs: map[string]string{"com.vibecare.dup": addr},
		stops: map[string]func(){"com.vibecare.dup": func() {}},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)
	t.Cleanup(reg.Stop)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	list := reg.List()
	if len(list) != 1 {
		t.Fatalf("List() = %+v, want exactly 1 plugin (duplicate id skipped)", list)
	}
	if list[0].Name != "Dup A" {
		t.Errorf("expected the first-discovered manifest (Dup A) to win, got %+v", list[0])
	}

	if got := fl.callCount("com.vibecare.dup"); got != 1 {
		t.Errorf("launcher.launch called %d times for duplicate id, want exactly 1 — "+
			"the duplicate must be rejected before ever being launched", got)
	}
}

// TestRegistryStartSkipsSecondDistinctPluginID verifies the single-plugin
// guard (the mitigation for the known plugin-id-namespacing-not-wired-in-
// production limitation, see the design doc's "Known Limitations (v1)"):
// when two manifests in different directories declare two DIFFERENT plugin
// ids, only the first (by deterministic, sorted discovery order) loads —
// the second is skipped even though it's not a duplicate id. This mirrors
// TestRegistryStartSkipsDuplicatePluginID's assertion style but is a
// distinct code path: that test guards against the SAME id from two
// directories, this one guards against a SECOND distinct id entirely, since
// today all plugins share the empty plugin_id storage namespace and can't
// safely coexist.
func TestRegistryStartSkipsSecondDistinctPluginID(t *testing.T) {
	root := t.TempDir()

	// os.ReadDir (as sorted explicitly by Registry.Start) discovers "first"
	// before "second", so "com.vibecare.first" is the one that must win.
	firstDir := filepath.Join(root, "first")
	writeManifest(t, firstDir, "com.vibecare.first", "First", "./first")

	secondDir := filepath.Join(root, "second")
	writeManifest(t, secondDir, "com.vibecare.second", "Second", "./second")

	firstAddr, firstStop := startStubPlugin(t, "com.vibecare.first")
	t.Cleanup(firstStop)

	secondAddr, secondStop := startStubPlugin(t, "com.vibecare.second")
	t.Cleanup(secondStop)

	fl := &fakeLauncher{
		addrs: map[string]string{
			"com.vibecare.first":  firstAddr,
			"com.vibecare.second": secondAddr,
		},
		stops: map[string]func(){
			"com.vibecare.first":  func() {},
			"com.vibecare.second": func() {},
		},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)
	t.Cleanup(reg.Stop)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	list := reg.List()
	if len(list) != 1 {
		t.Fatalf("List() = %+v, want exactly 1 plugin (second distinct id skipped by single-plugin guard)", list)
	}
	if list[0].ID != "com.vibecare.first" {
		t.Errorf("expected the first-discovered plugin (com.vibecare.first) to win, got %+v", list[0])
	}

	if _, ok := reg.Client("com.vibecare.second"); ok {
		t.Error("Client() should not find the second distinct plugin; the single-plugin guard should have skipped it")
	}

	if got := fl.callCount("com.vibecare.second"); got != 0 {
		t.Errorf("launcher.launch called %d times for the second distinct plugin id, want exactly 0 — "+
			"the single-plugin guard must reject it before ever being launched", got)
	}
}

// TestRegistryStopKillsSubprocessesAndHealthPolling verifies Stop() calls
// each plugin's stop func and does not panic or hang.
func TestRegistryStopKillsSubprocessesAndHealthPolling(t *testing.T) {
	root := t.TempDir()
	pluginDir := filepath.Join(root, "todos")
	writeManifest(t, pluginDir, "com.vibecare.todos", "Todos", "./todos")

	addr, stop := startStubPlugin(t, "com.vibecare.todos")
	t.Cleanup(stop)

	stopped := make(chan struct{}, 1)
	fl := &fakeLauncher{
		addrs: map[string]string{"com.vibecare.todos": addr},
		stops: map[string]func(){"com.vibecare.todos": func() {
			select {
			case stopped <- struct{}{}:
			default:
			}
		}},
	}

	reg := newRegistryWithLauncher(root, nil, "127.0.0.1:50051", zap.NewNop(), fl)

	if err := reg.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	reg.Stop()

	select {
	case <-stopped:
	default:
		t.Error("expected plugin stop func to be called by Registry.Stop()")
	}
}
