# VibeCare Plugin System — Spec 1: Plugin Spine + Native-Rendered Todos

> Design doc. Date: 2026-08-06. Branch: `feat/plugin-system`.
> Companion findings: [`docs/plugin-architecture-findings.md`](../../plugin-architecture-findings.md).
> This is **Spec 1 of a multi-slice platform** (see "Roadmap"). It covers only the plugin
> spine and one reference plugin. Later slices add web UI, native-module UI, and a registry.

## Interpretation to confirm first

"A simple todo plugin with **native VibeShell UI**" is designed here as:

- The **todos plugin is a headless Go process.** It owns todo data and logic. It contains
  **no Swift and no UI rendering code.**
- The **VibeShell (Swift client) renders the todo screen natively in SwiftUI**, driven by a
  small **declarative view descriptor** the plugin returns over RPC (server-driven UI,
  rendered natively — *not* a webview, *not* an in-process native bundle).
- The declarative vocabulary in v1 is **minimal — exactly what todos needs** (list, row,
  text, toggle, text-field, button), and is designed to be extended later.

If instead you meant "the todos plugin ships its own compiled SwiftUI module loaded into the
shell," that is the deferred `native` tier and this spec should change. **Please confirm the
interpretation above during spec review.**

## Goal

Turn VibeCare Core into a small **kernel** that hosts **plugins as separate RPC processes**
implementing an agreed contract, and prove the whole spine end-to-end with a **todos**
plugin that appears in the client's "Plugins" section with a natively-rendered screen.

Success = from a clean checkout: drop the todos plugin into `~/.vibecare/plugins/todos/`,
start Core, open the client, see **Plugins → Todos**, add/complete/delete todos in a native
SwiftUI screen, and have that data persist across restarts — with the plugin written in
**~50 lines of Go** on top of a first-party SDK.

## Non-goals (explicitly deferred to later slices)

- Sandboxing / untrusted third-party isolation. **Plugins are trusted** (same trust level as
  the existing MCP server). No WASM, no permission enforcement in v1.
- Web-UI tier and native-module (in-process bundle) UI tier. **Reserved in the manifest,
  not implemented.**
- A public/downloadable registry, signing, publishing. v1 discovery = a local folder.
- Multi-device / remote plugins. v1 assumes plugin + Core + client on one machine (localhost).
- activity-watch and vibecheck plugins (later slices; they reuse this exact contract).

## Architecture

```
Client (VibeShell, Swift)                Core (Go kernel)                 Plugin (Go process)
─────────────────────────                ────────────────                 ───────────────────
Plugins sidebar section    ── gRPC ──▶   PluginRegistry  ── gRPC ──▶       PluginService
  lists installed plugins                 discovers + supervises            GetManifest
Native SwiftUI renderer    ◀── descr. ──  proxies RenderView ◀───────────   Initialize
  (declarative vocab)                                                       HandleEvent
  sends InvokeAction     ──────────────▶  proxies InvokeAction ─────────▶   ExecuteAction
                                                                            RenderView
                                          HostService  ◀── gRPC callbacks ─ InvokeAction
                                            EmitEvent/Notify/Store/Query     HealthCheck
                                            GetSchedules/Log
                                          SQLite: plugin_data table
```

### Components

1. **Plugin contract (proto).** Two new gRPC services in a new file `proto/vibecare_plugin.proto`
   (package `vibecare.plugin.v1`), kept separate from the app contract so plugin authors depend
   on a small, stable file.

   ```proto
   // Plugin implements; Core calls.
   service PluginService {
     rpc GetManifest(google.protobuf.Empty) returns (Manifest);
     rpc Initialize(InitRequest) returns (google.protobuf.Empty); // host addr + config
     rpc HandleEvent(HostEvent) returns (google.protobuf.Empty);  // core forwards events
     rpc ExecuteAction(ExecuteActionRequest) returns (ExecuteActionResponse);
     rpc RenderView(RenderViewRequest) returns (ViewDescriptor);  // server-driven UI
     rpc InvokeAction(InvokeActionRequest) returns (InvokeActionResponse); // UI interaction
     rpc HealthCheck(google.protobuf.Empty) returns (Health);
   }

   // Core implements; Plugin calls back.
   service HostService {
     rpc EmitEvent(PluginEvent) returns (google.protobuf.Empty);
     rpc Notify(NotifyRequest) returns (google.protobuf.Empty);
     rpc StoreData(StoreRequest) returns (google.protobuf.Empty);
     rpc QueryData(QueryRequest) returns (QueryResponse);
     rpc Log(LogRequest) returns (google.protobuf.Empty);
   }
   ```

2. **Manifest** (`manifest.yaml` beside the plugin binary; also returned by `GetManifest`):
   ```yaml
   id: com.vibecare.todos
   name: Todos
   version: 0.1.0
   icon: checklist
   exec: ./todos                 # binary Core launches
   provides:
     actions: [add_todo, complete_todo, delete_todo]
     events: []                  # events this plugin emits (for the event registry)
     data: [todos]               # storage collections it owns
   ui:
     kind: shell-native          # v1: rendered by VibeShell. reserved: web | native
     entry: main                 # view id passed to RenderView
   ```

3. **Declarative view vocabulary (v1, minimal).** `ViewDescriptor` is a tree of nodes; the
   client renders each node to SwiftUI. v1 node kinds: `list`, `row`, `text`, `toggle`,
   `textField`, `button`, `spacer`. Each interactive node carries an `action_id` +
   `params` that the client sends back via `InvokeAction`. `InvokeActionResponse` returns a
   fresh `ViewDescriptor` (re-render) — simplest possible update model, no diffing in v1.

4. **Plugin registry + supervisor (Core, new pkg `internal/plugins/`).** Mirrors the MCP
   subprocess pattern already in the repo. On startup: scan `~/.vibecare/plugins/*/manifest.yaml`,
   launch each `exec` as a subprocess, dial its gRPC, call `GetManifest` then `Initialize`
   (passing Core's `HostService` address), register its actions/events/UI into the registries,
   poll `HealthCheck`, restart on crash (bounded), shut down cleanly on Core exit.

5. **Registries replacing closed enums (Core).** New in-memory registries populated from
   manifests: `ActionTypeRegistry`, `EventTypeRegistry`, `PluginUIRegistry`. The existing
   built-in `ActionType`s remain hardcoded and are *also* entered into the registry so the
   two coexist. Scheduler action dispatch and the new plugin-UI listing read the registry.

6. **Generic plugin storage (Core).** New goose migration adds:
   ```sql
   CREATE TABLE plugin_data (
     plugin_id  TEXT NOT NULL,
     collection TEXT NOT NULL,
     key        TEXT NOT NULL,
     value_json TEXT NOT NULL,
     updated_at TIMESTAMP NOT NULL,
     PRIMARY KEY (plugin_id, collection, key)
   );
   ```
   `HostService.StoreData/QueryData` read/write this table, namespaced by `plugin_id`
   (Core injects the caller's id — a plugin cannot address another plugin's namespace).

7. **New app-facing RPCs (Core → client) for listing + rendering plugins.** Add a small
   `PluginHostService` on the app gRPC surface (`proto/vibecare.proto`) the client uses:
   `ListPlugins`, `RenderPluginView(plugin_id, view_id, params)` (Core proxies to the
   plugin's `RenderView`), `InvokePluginAction(...)` (proxies to `InvokeAction`). The client
   never talks to plugins directly — **Core is the only thing that talks to plugins.**

8. **Go plugin SDK (`sdk/go/vibecare/`).** Wraps all gRPC/lifecycle so a plugin is a few
   callbacks. Target ergonomics:
   ```go
   func main() {
     p := vibecare.New() // reads manifest.yaml, connects, serves, health
     p.OnAction("add_todo", func(c vibecare.Ctx, in map[string]string) error {
       return c.Host.Store("todos", uuid(), map[string]any{"text": in["text"], "done": false})
     })
     p.OnRender("main", func(c vibecare.Ctx) vibecare.View {
       todos := c.Host.Query("todos")
       return vibecare.List(todos.Map(func(t) vibecare.Node {
         return vibecare.Row(vibecare.Toggle(t.done, "complete_todo", t.id), vibecare.Text(t.text))
       }))
     })
     p.Run()
   }
   ```

9. **Client: Plugins section (VibeShell).** Add a `.plugins` case to `SidebarItem`
   (interim — until the enum becomes registry-driven in a later slice), a `PluginListView`
   (from `ListPlugins`), and a `PluginScreen` hosting the **generic declarative renderer**
   (`ViewDescriptor` → SwiftUI). Interactions call `InvokePluginAction`, swap in the returned
   descriptor.

### Reference plugin: `plugins/todos/` (Go)

Headless. Owns `todos` collection. Actions: `add_todo`, `complete_todo`, `delete_todo`.
Renders `main` as a list with an add field. ~50 lines on the SDK. No Swift.

## Data flow (add a todo)

1. User types in the add-field on the native Todos screen, taps Add.
2. Client → Core `InvokePluginAction(todos, "add_todo", {text})`.
3. Core → plugin `InvokeAction` (or `ExecuteAction`) → plugin calls `Host.StoreData("todos", …)`.
4. Core writes `plugin_data`. Plugin returns a fresh `ViewDescriptor` (list incl. new item).
5. Core relays the descriptor to the client; the native renderer redraws. Persists across restart.

## Error handling

- **Plugin crash / no health:** registry marks it `unavailable`; its Plugins-list row shows an
  error state; Core auto-restarts with backoff (max N, then give up). Core never crashes because
  a plugin did (separate process — the core reason for this architecture).
- **Manifest invalid / exec missing:** plugin is skipped, logged; other plugins load.
- **RenderView/InvokeAction timeout:** client shows an inline error in the pane, offers retry.
- **Storage namespace safety:** `plugin_id` is injected by Core from the connection, never
  taken from plugin input.

## Testing

- **Go SDK/plugin:** unit-test todos action handlers against a fake `Host`; table-test the
  view builder produces the expected `ViewDescriptor`.
- **Core registry/supervisor:** test discovery, launch, manifest parse, registry population,
  crash-restart backoff, storage namespacing (a plugin cannot read another's collection).
- **Contract:** golden-test the proto round-trips; a stub plugin exercises every RPC.
- **Client renderer:** snapshot-test `ViewDescriptor` → SwiftUI for each v1 node kind;
  test `InvokeAction` round-trip swaps the descriptor.
- **End-to-end (the acceptance test):** launch Core with the todos plugin, drive
  `ListPlugins` → `RenderPluginView` → `InvokePluginAction(add)` → assert the item persists
  and re-renders.

## Known Limitations (v1)

- **~~Plugin-id namespacing is unit-proven but not wired in production.~~ RESOLVED.**
  Plugin-id attribution is now wired end-to-end: the SDK sends the plugin id as gRPC call
  metadata (`x-vibecare-plugin-id`) on every `HostClient` call, and Core installs a matching
  unary interceptor (`plugins.PluginIDUnaryServerInterceptor`) that sets it on the context
  before the request reaches `HostService`. The single-plugin guard in `Registry` has been
  removed; multiple distinct plugins now load and get separate storage namespaces. See
  [`2026-08-06-plugin-id-namespacing-wiring-design.md`](2026-08-06-plugin-id-namespacing-wiring-design.md).

  **Follow-up (future security review):** the plugin id is *self-reported* metadata, which
  is acceptable under v1's trusted-plugin model. Before untrusted/sandboxed plugins ship,
  move to **server-bound identity** (a per-plugin `HostService` listener whose id is fixed
  server-side) so a plugin cannot spoof another's namespace.

- **`EmitEvent` is a log-only no-op.** `HostService.EmitEvent` does not broadcast anything to
  connected clients in v1 — it only logs the plugin id, event type, and payload. A real
  `DispatchEvent` has no faithful mapping from an arbitrary plugin event yet (no `EventType`
  for plugin-originated events, and events aren't profile-scoped), so building one would only
  produce a meaningless `EVENT_TYPE_UNSPECIFIED` broadcast to every client's stream. Real event
  dispatch (a proper `EventType` plus routing to the right profile's subscribers) is deferred,
  not part of v1.

## Roadmap (later slices, each its own spec)

- **Spec 2 — Web UI tier:** `ui.kind: web`; plugin serves HTML; client embeds a webview;
  optional VibeCare design kit. For richer/independent UIs.
- **Spec 3 — Native-module tier:** `ui.kind: native`; per-platform in-process bundle loading
  with library-evolution discipline; the premium native tier.
- **Spec 4 — Native providers:** activity-watch, vibecheck — same contract, device/hardware
  capabilities, native processes (already possible on this spine; these are just plugins).
- **Spec 5 — Registry + distribution:** bundle format, discovery beyond a local folder,
  signing/trust UX, enum→registry migration for `SidebarItem`.

## Open questions for spec review

1. Confirm the "native VibeShell UI = server-driven, natively-rendered" interpretation above.
2. v1 view vocabulary: is `list/row/text/toggle/textField/button/spacer` enough for todos,
   or do you want (e.g.) sections/swipe-to-delete now?
3. SDK language for v1: **Go only** (todos is Go). Swift SDK deferred — agreed?
4. Where should plugins live and be launched from — Core backend supervises (this spec), vs
   the client supervising device-local plugins (matters for vibecheck later, not now)?
