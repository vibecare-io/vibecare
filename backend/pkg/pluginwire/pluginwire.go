// Package pluginwire holds constants shared across the plugin wire contract
// between the kernel (backend/kernel) and the plugin SDK (backend/pkg/vc).
// It has no dependencies, so the SDK can import it without coupling to
// kernel internals.
package pluginwire

// PluginIDMetadataKey is the gRPC call-metadata key the plugin SDK sets on
// every call back into the kernel and the kernel's server interceptor reads
// to attribute the call to a plugin. It is the single source of truth for
// that key: both sides import it rather than duplicating the literal,
// because a silent drift between them would be a storage-namespacing
// (security) failure, not a mere parse error.
const PluginIDMetadataKey = "x-vibecare-plugin-id"
