package plugins

import (
	"context"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// PluginIDUnaryServerInterceptor returns a unary server interceptor that reads
// the calling plugin's id from pluginwire.PluginIDMetadataKey incoming call
// metadata (set by the plugin SDK) and puts it on the request context via the
// same key HostService's methods read through pluginIDFromContext. This is what
// namespaces StoreData/QueryData/DeleteData per plugin in production.
//
// It is installed on Core's shared gRPC server, so it also runs for Core's
// own app-facing RPCs — those carry no plugin-id metadata, so the id is simply
// empty and the request passes through unchanged.
//
// The id is self-reported by the (trusted, v1) plugin. See the design doc
// docs/superpowers/specs/2026-08-06-plugin-id-namespacing-wiring-design.md
// "Future security review" for the server-bound-identity follow-up needed
// before untrusted plugins.
func PluginIDUnaryServerInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if md, ok := metadata.FromIncomingContext(ctx); ok {
			if vals := md.Get(pluginwire.PluginIDMetadataKey); len(vals) > 0 {
				ctx = context.WithValue(ctx, pluginIDContextKey{}, vals[0])
			}
		}
		return handler(ctx, req)
	}
}
