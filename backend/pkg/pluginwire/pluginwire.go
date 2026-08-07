// Package pluginwire holds constants shared across the plugin wire contract
// between Core (backend/internal/plugins) and the plugin SDK
// (backend/pkg/pluginsdk). It has no dependencies, so the SDK can import it
// without coupling to Core internals.
package pluginwire

// PluginIDMetadataKey is the gRPC call-metadata key the plugin SDK sets on
// every HostService callback and Core's server interceptor reads to attribute
// the call to a plugin. It is the single source of truth for that key: both
// sides import it rather than duplicating the literal, because a silent drift
// between them would be a storage-namespacing (security) failure, not a mere
// parse error.
const PluginIDMetadataKey = "x-vibecare-plugin-id"
