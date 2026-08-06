package api

import (
	"context"
	"testing"

	"github.com/vibecare-io/vibecare/backend/internal/plugins"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakePluginServiceClient implements pb.PluginServiceClient directly (it's a
// Go interface), returning canned responses so tests never need a real
// server or subprocess.
type fakePluginServiceClient struct {
	renderViewReq    *pb.RenderViewRequest
	renderViewResp   *pb.ViewDescriptor
	renderViewErr    error
	invokeActionReq  *pb.InvokeActionRequest
	invokeActionResp *pb.InvokeActionResponse
	invokeActionErr  error
}

func (f *fakePluginServiceClient) GetManifest(ctx context.Context, in *emptypb.Empty, opts ...grpc.CallOption) (*pb.Manifest, error) {
	return nil, status.Error(codes.Unimplemented, "not used in this test")
}

func (f *fakePluginServiceClient) Initialize(ctx context.Context, in *pb.InitRequest, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	return nil, status.Error(codes.Unimplemented, "not used in this test")
}

func (f *fakePluginServiceClient) HandleEvent(ctx context.Context, in *pb.HostEvent, opts ...grpc.CallOption) (*emptypb.Empty, error) {
	return nil, status.Error(codes.Unimplemented, "not used in this test")
}

func (f *fakePluginServiceClient) ExecuteAction(ctx context.Context, in *pb.PluginExecuteActionRequest, opts ...grpc.CallOption) (*pb.PluginExecuteActionResponse, error) {
	return nil, status.Error(codes.Unimplemented, "not used in this test")
}

func (f *fakePluginServiceClient) RenderView(ctx context.Context, in *pb.RenderViewRequest, opts ...grpc.CallOption) (*pb.ViewDescriptor, error) {
	f.renderViewReq = in
	return f.renderViewResp, f.renderViewErr
}

func (f *fakePluginServiceClient) InvokeAction(ctx context.Context, in *pb.InvokeActionRequest, opts ...grpc.CallOption) (*pb.InvokeActionResponse, error) {
	f.invokeActionReq = in
	return f.invokeActionResp, f.invokeActionErr
}

func (f *fakePluginServiceClient) HealthCheck(ctx context.Context, in *emptypb.Empty, opts ...grpc.CallOption) (*pb.Health, error) {
	return nil, status.Error(codes.Unimplemented, "not used in this test")
}

// fakePluginHost implements the PluginHost seam so tests never need a real
// plugins.Registry (which requires the plugins package's test-only fake
// launcher to populate).
type fakePluginHost struct {
	list    []plugins.PluginInfo
	clients map[string]pb.PluginServiceClient
}

func (f *fakePluginHost) List() []plugins.PluginInfo {
	return f.list
}

func (f *fakePluginHost) Client(id string) (pb.PluginServiceClient, bool) {
	c, ok := f.clients[id]
	return c, ok
}

func newTestPluginHostService(host *fakePluginHost) *PluginHostService {
	return NewPluginHostService(host, zap.NewNop())
}

func TestListPluginsMapsPluginInfoToSummaries(t *testing.T) {
	host := &fakePluginHost{
		list: []plugins.PluginInfo{
			{ID: "com.vibecare.foo", Name: "Foo", Icon: "foo.svg", UIKind: "shell-native", UIEntry: "main", Status: "ready"},
			{ID: "com.vibecare.bar", Name: "Bar", Icon: "bar.svg", UIKind: "none", UIEntry: "", Status: "unavailable"},
		},
	}
	svc := newTestPluginHostService(host)

	resp, err := svc.ListPlugins(context.Background(), &emptypb.Empty{})
	if err != nil {
		t.Fatalf("ListPlugins returned error: %v", err)
	}
	if len(resp.Plugins) != 2 {
		t.Fatalf("expected 2 plugin summaries, got %d", len(resp.Plugins))
	}

	byID := map[string]*pb.PluginSummary{}
	for _, p := range resp.Plugins {
		byID[p.Id] = p
	}

	foo, ok := byID["com.vibecare.foo"]
	if !ok {
		t.Fatalf("missing summary for com.vibecare.foo")
	}
	if foo.Name != "Foo" || foo.Icon != "foo.svg" || foo.UiKind != "shell-native" || foo.UiEntry != "main" || foo.Status != "ready" {
		t.Errorf("unexpected foo summary: %+v", foo)
	}

	bar, ok := byID["com.vibecare.bar"]
	if !ok {
		t.Fatalf("missing summary for com.vibecare.bar")
	}
	if bar.Status != "unavailable" {
		t.Errorf("expected bar status unavailable, got %q", bar.Status)
	}
}

func TestRenderPluginViewProxiesToClient(t *testing.T) {
	wantView := &pb.ViewDescriptor{
		Nodes: []*pb.Node{{Kind: "text", Text: "hello"}},
	}
	fakeClient := &fakePluginServiceClient{renderViewResp: wantView}
	host := &fakePluginHost{
		list:    []plugins.PluginInfo{{ID: "com.vibecare.foo", Status: "ready"}},
		clients: map[string]pb.PluginServiceClient{"com.vibecare.foo": fakeClient},
	}
	svc := newTestPluginHostService(host)

	req := &pb.RenderPluginViewRequest{
		PluginId: "com.vibecare.foo",
		ViewId:   "main",
		Params:   map[string]string{"k": "v"},
	}
	got, err := svc.RenderPluginView(context.Background(), req)
	if err != nil {
		t.Fatalf("RenderPluginView returned error: %v", err)
	}
	if got != wantView {
		t.Errorf("expected proxied ViewDescriptor, got %+v", got)
	}
	if fakeClient.renderViewReq == nil {
		t.Fatalf("expected RenderView to be called on plugin client")
	}
	if fakeClient.renderViewReq.ViewId != "main" || fakeClient.renderViewReq.Params["k"] != "v" {
		t.Errorf("RenderView called with unexpected request: %+v", fakeClient.renderViewReq)
	}
}

func TestInvokePluginActionProxiesToClient(t *testing.T) {
	wantView := &pb.ViewDescriptor{
		Nodes: []*pb.Node{{Kind: "toggle", BoolValue: true}},
	}
	fakeClient := &fakePluginServiceClient{
		invokeActionResp: &pb.InvokeActionResponse{View: wantView},
	}
	host := &fakePluginHost{
		list:    []plugins.PluginInfo{{ID: "com.vibecare.foo", Status: "ready"}},
		clients: map[string]pb.PluginServiceClient{"com.vibecare.foo": fakeClient},
	}
	svc := newTestPluginHostService(host)

	req := &pb.InvokePluginActionRequest{
		PluginId: "com.vibecare.foo",
		ViewId:   "main",
		Action:   "toggle-thing",
		Params:   map[string]string{"id": "123"},
	}
	got, err := svc.InvokePluginAction(context.Background(), req)
	if err != nil {
		t.Fatalf("InvokePluginAction returned error: %v", err)
	}
	if got != wantView {
		t.Errorf("expected proxied ViewDescriptor, got %+v", got)
	}
	if fakeClient.invokeActionReq == nil {
		t.Fatalf("expected InvokeAction to be called on plugin client")
	}
	if fakeClient.invokeActionReq.Action != "toggle-thing" || fakeClient.invokeActionReq.Params["id"] != "123" {
		t.Errorf("InvokeAction called with unexpected request: %+v", fakeClient.invokeActionReq)
	}
}

func TestRenderPluginViewUnknownPluginReturnsGRPCError(t *testing.T) {
	host := &fakePluginHost{}
	svc := newTestPluginHostService(host)

	_, err := svc.RenderPluginView(context.Background(), &pb.RenderPluginViewRequest{
		PluginId: "com.vibecare.nonexistent",
		ViewId:   "main",
	})
	if err == nil {
		t.Fatalf("expected an error for unknown plugin id, got nil")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected a gRPC status error, got %v (%T)", err, err)
	}
	if st.Code() != codes.NotFound {
		t.Errorf("expected codes.NotFound, got %v", st.Code())
	}
}

func TestInvokePluginActionUnknownPluginReturnsGRPCError(t *testing.T) {
	host := &fakePluginHost{}
	svc := newTestPluginHostService(host)

	_, err := svc.InvokePluginAction(context.Background(), &pb.InvokePluginActionRequest{
		PluginId: "com.vibecare.nonexistent",
		ViewId:   "main",
		Action:   "noop",
	})
	if err == nil {
		t.Fatalf("expected an error for unknown plugin id, got nil")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("expected a gRPC status error, got %v (%T)", err, err)
	}
	if st.Code() != codes.NotFound {
		t.Errorf("expected codes.NotFound, got %v", st.Code())
	}
}
