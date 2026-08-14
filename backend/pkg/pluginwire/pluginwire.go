// Package pluginwire holds constants shared across the plugin wire contract
// between the kernel (backend/kernel) and the plugin SDK (backend/pkg/vc).
// It has no dependencies, so the SDK can import it without coupling to
// kernel internals.
package pluginwire

// PluginIDMetadataKey is the gRPC call-metadata key the plugin SDK's
// client interceptors (vc.attributionInterceptor and
// attributionStreamInterceptor) attach to every outbound call, and that
// rpc.go's callerID reads straight off the incoming context to attribute a
// Publish or Alert to the caller. It is the single source of truth for
// that key: both sides import it rather than duplicating the literal,
// because a silent drift between them would let a plugin's calls go
// unattributed (rejected) or, worse, let one plugin's traffic be
// misattributed to another — Publish trusts this value instead of any
// self-declared field precisely so a plugin cannot claim to be a different
// one.
const PluginIDMetadataKey = "x-vibecare-plugin-id"
