# Wire Per-Plugin Storage Namespacing (Metadata) — Design

> Design doc. Date: 2026-08-06. Branch: `feat/plugin-system`.
> Follows: [`2026-08-06-plugin-system-v1-design.md`](2026-08-06-plugin-system-v1-design.md)
> — this implements that spec's "Real fix (first task of the next slice)" for the
> plugin-id namespacing limitation.

## Problem

`HostService` (`backend/internal/plugins/host_service.go`) already namespaces
`StoreData`/`QueryData`/`DeleteData` by a plugin id read from the request context
via `WithPluginID`, and that namespacing is unit-proven. But nothing wires the id
end-to-end:

- The SDK's `HostClient` (`backend/pkg/pluginsdk/plugin.go`) sends **no** plugin id
  on its callbacks.
- `cmd/server/main.go` registers `HostService` with **no** interceptor that calls
  `WithPluginID`.

So every real callback lands in the **empty** `plugin_id` namespace. To avoid a
second plugin silently corrupting the first's data, `Registry.loadOne`
(`registry.go`) refuses to load a second distinct plugin id. In practice that means
with `todos` and `vibecheck` both installed, `todos` loads (sorted first) and
`vibecheck` is skipped with a loud warning — the bug that motivated this work.

## Approach

**Self-reported plugin id via gRPC metadata.** The SDK attaches the plugin's own id
as call metadata on every `HostClient` call; Core reads it in a unary server
interceptor and sets it on the context via `WithPluginID` before the request reaches
`HostService`. This matches the primary recommendation in the v1 spec's "Real fix"
and fits the v1 **trusted-plugin** model (plugins run at the same trust level as the
MCP server — no sandboxing in v1).

**Security note / deferred:** because the id is self-reported, a buggy or hostile
plugin could set another plugin's id and reach its namespace. This is acceptable
under the v1 trust model (a trusted-but-hostile plugin has many other avenues,
including writing `~/.vibecare/vibecare.db` directly). When untrusted/sandboxed
plugins land (a future slice), move to **server-bound identity** — a per-plugin
`HostService` listener whose id is fixed server-side so it cannot be spoofed. See
"Future security review" below.

## Components

### 1. Shared metadata key — `backend/pkg/pluginwire` (new)

A minimal package exporting one constant, imported by both the SDK and Core:

```go
package pluginwire

// PluginIDMetadataKey is the gRPC metadata key the plugin SDK sets on every
// HostService callback and Core's interceptor reads to attribute the call.
const PluginIDMetadataKey = "x-vibecare-plugin-id"
```

Unlike the SDK's deliberately-duplicated `fileManifest` struct, this key is **not**
duplicated: a silent drift between the two sides would be a namespacing (security)
failure, not a parse error, so it lives in one shared place. The package has zero
dependencies, so the SDK importing it introduces no coupling to Core internals.

### 2. SDK — inject the id (`pkg/pluginsdk/plugin.go`)

When `start()` dials `hostAddr`, add a **client-side chained unary interceptor** that
appends the id to every outbound call:

```go
grpc.WithChainUnaryInterceptor(func(ctx, method, req, reply, cc, invoker, opts...) error {
    if p.manifest.ID != "" {
        ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, p.manifest.ID)
    }
    return invoker(ctx, method, req, reply, cc, opts...)
})
```

Every `Store/Query/Delete/Notify/Emit/Log` call carries the id with no per-method
change. Empty id (e.g. a test manifest with no id) → no metadata appended, preserving
the pre-wiring behavior.

### 3. Core — read the id (`internal/plugins/host_service.go`)

Add an exported constructor in the `plugins` package:

```go
func PluginIDUnaryServerInterceptor() grpc.UnaryServerInterceptor
```

It reads `PluginIDMetadataKey` from `metadata.FromIncomingContext`; if present, sets
the id on the context via the package-private key (same key `WithPluginID` uses).
Absent metadata → passes ctx through unchanged, so Core's app-facing RPCs sharing the
same gRPC server are unaffected.

### 4. Wire it in `cmd/server/main.go`

Install the interceptor **unconditionally**. Today the interceptor chain is only built
when `--enable-tracing` is set; restructure so `plugins.PluginIDUnaryServerInterceptor()`
is always in the chain, with the tracing trio (panic-recovery → otel → telemetry)
prepended when tracing is on. The plugin-id interceptor runs **last** (closest to the
handler) — it only reads metadata, so there is no ordering hazard.

### 5. Remove the single-plugin guard (`internal/plugins/registry.go`)

Delete the `loadedCount > 0` refusal in `loadOne` and the `loadedCount` read. Keep the
`sort.Slice` on discovered entries (deterministic load order is still desirable) but
rewrite its comment: it no longer guards anything. Keep the duplicate-**same**-id skip.

### 6. Comment cleanup + spec note

Strip the `KNOWN LIMITATION (v1)` blocks now resolved: in `registry.go`,
`host_service.go` (the type doc + `WithPluginID` note), and `main.go`. In the v1 spec's
"Known Limitations (v1)" section, replace the namespacing limitation with a short
"resolved, see this doc" note plus the forward-looking self-report/server-bound item.

The `EmitEvent` log-only no-op limitation is **untouched** — separate and still valid.

## Data flow (after wiring)

1. Plugin handler calls `c.Host.Store("todos", key, val)`.
2. SDK client interceptor appends `x-vibecare-plugin-id: com.vibecare.todos` metadata.
3. Core's `PluginIDUnaryServerInterceptor` reads it, sets ctx via `WithPluginID`.
4. `HostService.StoreData` reads the id from ctx → writes `plugin_data` under that id.
5. A second plugin (`com.vibecare.vibecheck`) storing collection `todos` writes under
   its **own** id — no collision.

## Testing

- **Core interceptor** (`host_service_test.go` or new): call the interceptor with a ctx
  carrying the metadata → the wrapped handler observes the id via `pluginIDFromContext`;
  with no metadata → empty id.
- **Registry, two plugins** (`registry_test.go`): fake-launcher loads two plugins with
  distinct ids; both reach `ready` (proving the guard is gone). Drive Store through the
  real interceptor for each and assert separate namespaces (a plugin cannot read the
  other's collection).
- **SDK** (`plugin_test.go`): assert the client interceptor injects
  `PluginIDMetadataKey` = `manifest.ID` on an outbound call (via a stub HostService
  server that captures incoming metadata).

## Future security review

The v1 model trusts plugins, so a self-reported id is acceptable. Before any
untrusted/third-party plugin support ships, revisit: move to **server-bound identity**
(per-plugin `HostService` listener, id fixed at bind time) so a plugin cannot address
another's namespace even if it lies. Tracked as a known limitation in the v1 spec.

## Non-goals

- `EmitEvent` real dispatch — unchanged, still deferred.
- Server-bound identity / sandboxing — deferred to the untrusted-plugins slice.
- Any change to the storage schema or the `plugin_data` table.
