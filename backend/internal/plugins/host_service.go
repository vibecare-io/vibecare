// Package plugins implements the Core side of the plugin contract: the
// HostService gRPC server that plugins call back into for storage, events,
// notifications, and logging.
package plugins

import (
	"context"

	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/emptypb"
)

// pluginIDContextKey is an unexported type to avoid context key collisions.
type pluginIDContextKey struct{}

// HostService implements pb.HostServiceServer — the callback API plugins use
// to talk back to Core. A single HostService instance serves every plugin;
// each incoming call is attributed to a plugin via a context value set with
// WithPluginID (by the supervisor, per-connection), never from request fields.
// This is what gives StoreData/QueryData their namespacing guarantee.
//
// KNOWN LIMITATION (v1): nothing in production actually calls WithPluginID
// yet — cmd/server/main.go registers HostService with no interceptor, and
// the SDK's HostClient sends no plugin id, so every real call is attributed
// to the empty plugin id. Namespacing is unit-proven (see host_service_test.go)
// but not wired end-to-end. This is safe today only because Registry refuses
// to load a second distinct plugin id (see the guard in registry.go); wiring
// the SDK-sends-id + host-interceptor path is the first task of the next
// slice. See docs/superpowers/specs/2026-08-06-plugin-system-v1-design.md
// "Known Limitations (v1)".
type HostService struct {
	pb.UnimplementedHostServiceServer

	db     *storage.DB
	hub    *scheduler.EventHub
	logger *zap.Logger
}

// NewHostService constructs a HostService.
func NewHostService(db *storage.DB, hub *scheduler.EventHub, logger *zap.Logger) *HostService {
	return &HostService{
		db:     db,
		hub:    hub,
		logger: logger,
	}
}

// WithPluginID returns a copy of ctx carrying the calling plugin's id.
//
// NOTE: as of v1, nothing in production calls this on the real request path
// (see the KNOWN LIMITATION note on HostService above) — it's exercised
// directly by tests. Only single-plugin operation is safe until a gRPC
// interceptor (fed by the SDK sending the plugin id as call metadata) wires
// this into every real HostService call.
func (h *HostService) WithPluginID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, pluginIDContextKey{}, id)
}

// pluginIDFromContext reads the plugin id set by WithPluginID, or "" if unset.
func pluginIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(pluginIDContextKey{}).(string)
	return id
}

// StoreData upserts a value in the calling plugin's namespaced storage.
// The plugin id comes from ctx, never from the request, so plugins can never
// read or overwrite each other's data.
func (h *HostService) StoreData(ctx context.Context, req *pb.StoreRequest) (*emptypb.Empty, error) {
	pluginID := pluginIDFromContext(ctx)
	if err := h.db.StorePluginData(pluginID, req.GetCollection(), req.GetKey(), req.GetValueJson()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

// QueryData returns all records the calling plugin has stored in a collection.
// The plugin id comes from ctx, never from the request.
func (h *HostService) QueryData(ctx context.Context, req *pb.QueryRequest) (*pb.QueryResponse, error) {
	pluginID := pluginIDFromContext(ctx)
	records, err := h.db.QueryPluginData(pluginID, req.GetCollection())
	if err != nil {
		return nil, err
	}

	pbRecords := make([]*pb.Record, 0, len(records))
	for _, rec := range records {
		pbRecords = append(pbRecords, &pb.Record{
			Key:       rec.Key,
			ValueJson: rec.ValueJSON,
		})
	}

	return &pb.QueryResponse{Records: pbRecords}, nil
}

// DeleteData removes a value from the calling plugin's namespaced storage.
// The plugin id comes from ctx, never from the request, so plugins can never
// delete another plugin's data. Deleting a key that doesn't exist is a no-op.
func (h *HostService) DeleteData(ctx context.Context, req *pb.DeleteRequest) (*emptypb.Empty, error) {
	pluginID := pluginIDFromContext(ctx)
	if err := h.db.DeletePluginData(pluginID, req.GetCollection(), req.GetKey()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

// EmitEvent is a log-only no-op in v1. A real DispatchEvent has no faithful
// mapping from an arbitrary plugin event yet (there's no EventType for
// plugin-originated events, and events aren't profile-scoped), so building
// one here would only produce an EVENT_TYPE_UNSPECIFIED event broadcast to
// every connected client's stream — meaningless noise, not a real feature.
// Instead this just logs what the plugin emitted; wiring actual dispatch
// (a real EventType + routing to the right profile's subscribers) is future
// work, not part of v1. Signature and no-error contract are preserved so
// plugins calling Emit today don't need to change when that lands.
func (h *HostService) EmitEvent(ctx context.Context, req *pb.PluginEvent) (*emptypb.Empty, error) {
	pluginID := pluginIDFromContext(ctx)

	h.logger.Info("Plugin emitted event (log-only no-op in v1; not broadcast)",
		zap.String("plugin_id", pluginID),
		zap.String("event_type", req.GetType()),
		zap.Any("payload", req.GetPayload()))

	return &emptypb.Empty{}, nil
}

// Notify surfaces a plugin-originated notification. v1: this only logs the
// notification — there is no real user-facing notification path yet.
func (h *HostService) Notify(ctx context.Context, req *pb.NotifyRequest) (*emptypb.Empty, error) {
	pluginID := pluginIDFromContext(ctx)

	h.logger.Info("Plugin notification",
		zap.String("plugin_id", pluginID),
		zap.String("title", req.GetTitle()),
		zap.String("message", req.GetMessage()))

	return &emptypb.Empty{}, nil
}

// Log writes a plugin's log line through Core's structured logger, tagged
// with the calling plugin's id.
func (h *HostService) Log(ctx context.Context, req *pb.LogRequest) (*emptypb.Empty, error) {
	pluginID := pluginIDFromContext(ctx)

	fields := []zap.Field{
		zap.String("plugin_id", pluginID),
	}

	switch req.GetLevel() {
	case "debug":
		h.logger.Debug(req.GetMessage(), fields...)
	case "warn", "warning":
		h.logger.Warn(req.GetMessage(), fields...)
	case "error":
		h.logger.Error(req.GetMessage(), fields...)
	default:
		h.logger.Info(req.GetMessage(), fields...)
	}

	return &emptypb.Empty{}, nil
}
