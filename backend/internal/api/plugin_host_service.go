package api

import (
	"context"

	"github.com/vibecare-io/vibecare/backend/internal/plugins"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// PluginHost is the seam PluginHostService depends on instead of the
// concrete *plugins.Registry. *plugins.Registry satisfies this interface;
// tests supply a fake so they never need a real Registry (which can only be
// populated via the plugins package's test-only fake launcher) or a real
// plugin subprocess/server.
type PluginHost interface {
	List() []plugins.PluginInfo
	Client(id string) (pb.PluginServiceClient, bool)
}

// PluginHostService implements pb.PluginHostServiceServer — the app-facing
// API the Swift client calls. It never talks to plugins directly; every
// call is proxied to the right plugin's gRPC client via PluginHost. The
// client only ever talks to Core; Core is the only thing that talks to
// plugins.
type PluginHostService struct {
	pb.UnimplementedPluginHostServiceServer

	host   PluginHost
	logger *zap.Logger
}

// NewPluginHostService constructs a PluginHostService.
func NewPluginHostService(host PluginHost, logger *zap.Logger) *PluginHostService {
	return &PluginHostService{
		host:   host,
		logger: logger,
	}
}

// ListPlugins returns a summary of every loaded plugin.
func (s *PluginHostService) ListPlugins(ctx context.Context, _ *emptypb.Empty) (*pb.ListPluginsResponse, error) {
	infos := s.host.List()

	summaries := make([]*pb.PluginSummary, 0, len(infos))
	for _, info := range infos {
		summaries = append(summaries, &pb.PluginSummary{
			Id:      info.ID,
			Name:    info.Name,
			Icon:    info.Icon,
			UiKind:  info.UIKind,
			UiEntry: info.UIEntry,
			Status:  info.Status,
		})
	}

	return &pb.ListPluginsResponse{Plugins: summaries}, nil
}

// RenderPluginView proxies to the target plugin's RenderView RPC and
// returns its ViewDescriptor directly.
func (s *PluginHostService) RenderPluginView(ctx context.Context, req *pb.RenderPluginViewRequest) (*pb.ViewDescriptor, error) {
	client, ok := s.host.Client(req.GetPluginId())
	if !ok {
		return nil, status.Errorf(codes.NotFound, "plugin %q not found or not ready", req.GetPluginId())
	}

	view, err := client.RenderView(ctx, &pb.RenderViewRequest{
		ViewId: req.GetViewId(),
		Params: req.GetParams(),
	})
	if err != nil {
		s.logger.Warn("plugin RenderView failed",
			zap.String("plugin_id", req.GetPluginId()),
			zap.String("view_id", req.GetViewId()),
			zap.Error(err))
		return nil, status.Errorf(codes.Internal, "render view for plugin %q: %v", req.GetPluginId(), err)
	}

	return view, nil
}

// InvokePluginAction proxies to the target plugin's InvokeAction RPC and
// returns the resulting (re-rendered) ViewDescriptor.
func (s *PluginHostService) InvokePluginAction(ctx context.Context, req *pb.InvokePluginActionRequest) (*pb.ViewDescriptor, error) {
	client, ok := s.host.Client(req.GetPluginId())
	if !ok {
		return nil, status.Errorf(codes.NotFound, "plugin %q not found or not ready", req.GetPluginId())
	}

	resp, err := client.InvokeAction(ctx, &pb.InvokeActionRequest{
		ViewId: req.GetViewId(),
		Action: req.GetAction(),
		Params: req.GetParams(),
	})
	if err != nil {
		s.logger.Warn("plugin InvokeAction failed",
			zap.String("plugin_id", req.GetPluginId()),
			zap.String("view_id", req.GetViewId()),
			zap.String("action", req.GetAction()),
			zap.Error(err))
		return nil, status.Errorf(codes.Internal, "invoke action for plugin %q: %v", req.GetPluginId(), err)
	}

	return resp.GetView(), nil
}
