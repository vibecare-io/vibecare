package plugins

import (
	"context"
	"testing"

	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// TestPluginIDInterceptorSetsIDFromMetadata verifies the server interceptor
// reads pluginwire.PluginIDMetadataKey from incoming metadata and puts it on
// the context where HostService's methods read it via pluginIDFromContext.
func TestPluginIDInterceptorSetsIDFromMetadata(t *testing.T) {
	interceptor := PluginIDUnaryServerInterceptor()

	ctx := metadata.NewIncomingContext(context.Background(),
		metadata.Pairs(pluginwire.PluginIDMetadataKey, "com.vibecare.todos"))

	var seen string
	_, err := interceptor(ctx, nil, &grpc.UnaryServerInfo{},
		func(ctx context.Context, _ any) (any, error) {
			seen = pluginIDFromContext(ctx)
			return nil, nil
		})
	if err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}
	if seen != "com.vibecare.todos" {
		t.Errorf("handler saw plugin id %q, want %q", seen, "com.vibecare.todos")
	}
}

// TestPluginIDInterceptorEmptyWithoutMetadata verifies that a call carrying no
// plugin-id metadata (e.g. Core's own app-facing RPCs sharing the same gRPC
// server) passes through with an empty id rather than being rejected.
func TestPluginIDInterceptorEmptyWithoutMetadata(t *testing.T) {
	interceptor := PluginIDUnaryServerInterceptor()

	var seen = "sentinel"
	_, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{},
		func(ctx context.Context, _ any) (any, error) {
			seen = pluginIDFromContext(ctx)
			return nil, nil
		})
	if err != nil {
		t.Fatalf("interceptor returned error: %v", err)
	}
	if seen != "" {
		t.Errorf("handler saw plugin id %q, want empty", seen)
	}
}

// TestInterceptorNamespacesStorageEndToEnd drives StoreData/QueryData through
// the real interceptor + HostService + DB, attributing each call purely by
// incoming metadata (as the gRPC path does), and asserts two plugins that
// reuse the SAME collection+key cannot see each other's data. This is the
// composed guarantee the removed single-plugin guard used to stand in for.
func TestInterceptorNamespacesStorageEndToEnd(t *testing.T) {
	db := newTestDB(t)
	svc := NewHostService(db, scheduler.NewEventHub(zap.NewNop()), zap.NewNop())
	interceptor := PluginIDUnaryServerInterceptor()

	// ctxFor mimics an incoming gRPC call from a plugin that self-reports id.
	ctxFor := func(id string) context.Context {
		return metadata.NewIncomingContext(context.Background(),
			metadata.Pairs(pluginwire.PluginIDMetadataKey, id))
	}
	store := func(id, valueJSON string) {
		_, err := interceptor(ctxFor(id), &pb.StoreRequest{Collection: "todos", Key: "k1", ValueJson: valueJSON},
			&grpc.UnaryServerInfo{}, func(ctx context.Context, req any) (any, error) {
				return svc.StoreData(ctx, req.(*pb.StoreRequest))
			})
		if err != nil {
			t.Fatalf("StoreData for %s failed: %v", id, err)
		}
	}
	query := func(id string) []*pb.Record {
		resp, err := interceptor(ctxFor(id), &pb.QueryRequest{Collection: "todos"},
			&grpc.UnaryServerInfo{}, func(ctx context.Context, req any) (any, error) {
				return svc.QueryData(ctx, req.(*pb.QueryRequest))
			})
		if err != nil {
			t.Fatalf("QueryData for %s failed: %v", id, err)
		}
		return resp.(*pb.QueryResponse).GetRecords()
	}

	// Both plugins write the same collection+key with different values.
	store("com.vibecare.todos", `{"text":"todo-a"}`)
	store("com.vibecare.vibecheck", `{"text":"vibe-b"}`)

	todos := query("com.vibecare.todos")
	if len(todos) != 1 || todos[0].GetValueJson() != `{"text":"todo-a"}` {
		t.Errorf("todos plugin saw %+v, want only its own todo-a record", todos)
	}
	vibecheck := query("com.vibecare.vibecheck")
	if len(vibecheck) != 1 || vibecheck[0].GetValueJson() != `{"text":"vibe-b"}` {
		t.Errorf("vibecheck plugin saw %+v, want only its own vibe-b record", vibecheck)
	}
}
