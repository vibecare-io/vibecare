# Plugin System v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn VibeCare Core into a kernel that hosts plugins as trusted RPC processes, and prove it with a headless **todos** plugin rendered natively by the Swift client.

**Architecture:** A plugin is a subprocess speaking gRPC — it implements `PluginService`; Core implements `HostService` for callbacks (storage/events/notify). Core discovers plugins in `~/.vibecare/plugins/*/`, supervises them like the existing MCP server, and proxies UI calls from the client. The client renders a plugin's screen natively in SwiftUI from a declarative `ViewDescriptor` the plugin returns.

**Tech Stack:** Go 1.23 (backend + SDK + todos plugin), gRPC/protobuf, SQLite/goose, SwiftUI (client).

## Global Constraints

- **Everything Go lives in the existing backend module** `github.com/vibecare-io/vibecare/backend` — no new `go.mod` in v1 (extract the SDK later when third-party). Verbatim paths below.
- Plugin proto package: `vibecare.plugin.v1`; generated into `backend/pkg/proto` via `just proto-gen`. Never hand-edit generated stubs.
- **Trusted plugins, no sandbox** in v1. No permission enforcement.
- Client requires macOS 15+. Client talks only to Core, never directly to plugins.
- Storage namespacing: `plugin_id` is always injected by Core from the connection, never read from plugin input.
- TDD: failing test first. Commit after each task.

---

### Task 1: Plugin gRPC contract

**Files:**
- Create: `proto/vibecare_plugin.proto`
- Modify: `Justfile` (only if `proto-gen` doesn't already glob `proto/*.proto` — check first)
- Generated (do not edit): `backend/pkg/proto/vibecare_plugin*.go`

**Interfaces:**
- Produces: `PluginService` (GetManifest, Initialize, HandleEvent, ExecuteAction, RenderView, InvokeAction, HealthCheck) and `HostService` (EmitEvent, Notify, StoreData, QueryData, Log), plus messages below.

- [ ] **Step 1: Write the contract.** Create `proto/vibecare_plugin.proto`:

```proto
syntax = "proto3";
package vibecare.plugin.v1;
option go_package = "github.com/vibecare-io/vibecare/backend/pkg/proto";
import "google/protobuf/empty.proto";

service PluginService {
  rpc GetManifest(google.protobuf.Empty) returns (Manifest);
  rpc Initialize(InitRequest) returns (google.protobuf.Empty);
  rpc HandleEvent(HostEvent) returns (google.protobuf.Empty);
  rpc ExecuteAction(ExecuteActionRequest) returns (ExecuteActionResponse);
  rpc RenderView(RenderViewRequest) returns (ViewDescriptor);
  rpc InvokeAction(InvokeActionRequest) returns (InvokeActionResponse);
  rpc HealthCheck(google.protobuf.Empty) returns (Health);
}

service HostService {
  rpc EmitEvent(PluginEvent) returns (google.protobuf.Empty);
  rpc Notify(NotifyRequest) returns (google.protobuf.Empty);
  rpc StoreData(StoreRequest) returns (google.protobuf.Empty);
  rpc QueryData(QueryRequest) returns (QueryResponse);
  rpc Log(LogRequest) returns (google.protobuf.Empty);
}

message Manifest {
  string id = 1; string name = 2; string version = 3; string icon = 4;
  repeated string actions = 5; repeated string events = 6; repeated string data = 7;
  string ui_kind = 8;   // "shell-native" | "none" (reserved: "web","native")
  string ui_entry = 9;  // view id for RenderView
}
message InitRequest { string host_address = 1; string plugin_id = 2; }
message HostEvent { string type = 1; map<string,string> payload = 2; }
message ExecuteActionRequest { string action = 1; map<string,string> params = 2; }
message ExecuteActionResponse { bool ok = 1; string message = 2; }
message RenderViewRequest { string view_id = 1; map<string,string> params = 2; }
message InvokeActionRequest { string view_id = 1; string action = 2; map<string,string> params = 3; }
message InvokeActionResponse { ViewDescriptor view = 1; } // re-render, no diffing in v1
message Health { bool ok = 1; }

message PluginEvent { string type = 1; map<string,string> payload = 2; }
message NotifyRequest { string title = 1; string message = 2; }
message StoreRequest { string collection = 1; string key = 2; string value_json = 3; }
message QueryRequest { string collection = 1; }
message QueryResponse { repeated Record records = 1; }
message Record { string key = 1; string value_json = 2; }
message LogRequest { string level = 1; string message = 2; }

// Minimal declarative UI vocabulary (v1).
message ViewDescriptor { repeated Node nodes = 1; }
message Node {
  string kind = 1;      // list|row|text|toggle|textField|button|spacer
  string text = 2;
  bool bool_value = 3;
  string action = 4;    // action id sent back via InvokeAction
  map<string,string> params = 5;
  repeated Node children = 6;
}
```

- [ ] **Step 2: Generate.** Run `just proto-gen`. Expected: `backend/pkg/proto/vibecare_plugin*.go` created, build passes.
- [ ] **Step 3: Verify compile.** Run `cd backend && go build ./...`. Expected: PASS.
- [ ] **Step 4: Commit.** `git add proto/vibecare_plugin.proto backend/pkg/proto Justfile && git commit -m "feat(proto): plugin PluginService/HostService contract"`

---

### Task 2: Generic plugin storage

**Files:**
- Create: `backend/internal/storage/migrations/<goose-timestamp>_add_plugin_data.sql`
- Create: `backend/internal/storage/plugin_data.go`
- Test: `backend/internal/storage/plugin_data_test.go`

**Interfaces:**
- Produces: `func (db *DB) StorePluginData(pluginID, collection, key, valueJSON string) error`, `func (db *DB) QueryPluginData(pluginID, collection string) ([]PluginRecord, error)` where `type PluginRecord struct { Key, ValueJSON string }`.

- [ ] **Step 1: Create the migration.** Use `just new-migration add_plugin_data`, then fill the `-- +goose Up` block:

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
`-- +goose Down`: `DROP TABLE plugin_data;`

- [ ] **Step 2: Failing test.** In `plugin_data_test.go`: open a temp DB, `StorePluginData("p","todos","k1",`{"text":"a"}`)`, then `QueryPluginData("p","todos")` returns one record with that key/value; and `QueryPluginData("other","todos")` returns empty (namespacing). Run: `cd backend && go test ./internal/storage/ -run PluginData -v` → FAIL (undefined).
- [ ] **Step 3: Implement** `plugin_data.go` with the two methods (upsert via `INSERT ... ON CONFLICT(plugin_id,collection,key) DO UPDATE`).
- [ ] **Step 4: Run tests** → PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(storage): namespaced plugin_data table"`

---

### Task 3: HostService implementation

**Files:**
- Create: `backend/internal/plugins/host_service.go`
- Test: `backend/internal/plugins/host_service_test.go`

**Interfaces:**
- Consumes: `*storage.DB` (Task 2), `*scheduler.EventHub` (existing, for EmitEvent), `*zap.Logger`.
- Produces: `func NewHostService(db *storage.DB, hub *scheduler.EventHub, log *zap.Logger) *HostService` implementing `pb.HostServiceServer`. The `plugin_id` for storage comes from a per-connection value set by the supervisor (Task 4) via context — expose `func (h *HostService) WithPluginID(ctx, id)` helper and read it in handlers.

- [ ] **Step 1: Failing test.** Construct `HostService` with a temp DB + a no-op hub. Call `StoreData` (with plugin id "p" in ctx) then `QueryData` → returns the stored record. Call `Notify`/`Log`/`EmitEvent` → no error. Run → FAIL.
- [ ] **Step 2: Implement.** `StoreData/QueryData` delegate to Task 2 methods using the ctx plugin id; `EmitEvent` maps to a `pb.DispatchEvent` and calls `hub.Broadcast` (reuse existing event plumbing; for v1 emit under the plugin's profile or broadcast-to-all — pick broadcast-to-all, simplest); `Notify` logs + (v1) no-op beyond logging; `Log` writes via logger.
- [ ] **Step 3: Run tests** → PASS.
- [ ] **Step 4: Commit.** `git commit -am "feat(plugins): HostService (store/query/emit/notify/log)"`

---

### Task 4: Plugin registry + supervisor

**Files:**
- Create: `backend/internal/plugins/manifest.go` (parse `manifest.yaml`)
- Create: `backend/internal/plugins/registry.go` (discover, launch, supervise)
- Test: `backend/internal/plugins/registry_test.go`

**Interfaces:**
- Consumes: HostService (Task 3), a plugins dir path (default `~/.vibecare/plugins`).
- Produces: `type Registry struct{...}`; `func NewRegistry(dir string, host *HostService, hostAddr string, log *zap.Logger) *Registry`; `func (r *Registry) Start(ctx) error` (discovers + launches all); `func (r *Registry) List() []PluginInfo`; `func (r *Registry) Client(id string) (pb.PluginServiceClient, bool)`; `func (r *Registry) Stop()`. `type PluginInfo struct { ID, Name, Icon, UIKind, UIEntry, Status string }` (Status: "ready"|"unavailable").

- [ ] **Step 1: Failing test (manifest).** `manifest_test.go`: parse a sample yaml string → struct with id/name/actions/ui_kind. Run → FAIL. Implement `manifest.go` (use existing yaml dep; if none, `gopkg.in/yaml.v3`). PASS.
- [ ] **Step 2: Failing test (registry with a stub plugin).** Build a tiny in-test stub `PluginService` server (returns a fixed Manifest, Health ok, a canned ViewDescriptor). Point Registry at a temp dir containing a manifest whose `exec` is a script that... — simpler: allow `NewRegistry` to accept an injected launcher so tests skip real subprocess. Test: after `Start`, `List()` shows the plugin "ready" and `Client(id)` returns a working client. Run → FAIL.
- [ ] **Step 3: Implement `registry.go`:** scan `dir/*/manifest.yaml`; for each, launch `exec` (via an injectable `launcher` seam defaulting to `os/exec` + assign a localhost port, pass `--host <hostAddr>` and read the plugin's own listen addr from its stdout first line — keep the handshake dead simple); dial it; call `GetManifest` + `Initialize`; poll `HealthCheck` every 10s; on failure mark "unavailable" and restart with capped backoff. `Stop()` kills subprocesses.
- [ ] **Step 4: Run tests** → PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(plugins): registry + subprocess supervisor"`

---

### Task 5: App-facing PluginHostService (client ↔ Core)

**Files:**
- Modify: `proto/vibecare.proto` (add `PluginHostService`)
- Create: `backend/internal/api/plugin_host_service.go`
- Modify: `backend/internal/api/server.go` (register it), `backend/cmd/server/main.go` (build Registry + HostService, start them, inject into api)
- Test: `backend/internal/api/plugin_host_service_test.go`

**Interfaces:**
- Consumes: `*plugins.Registry` (Task 4).
- Produces proto:
```proto
service PluginHostService {
  rpc ListPlugins(google.protobuf.Empty) returns (ListPluginsResponse);
  rpc RenderPluginView(RenderPluginViewRequest) returns (vibecare.plugin.v1.ViewDescriptor);
  rpc InvokePluginAction(InvokePluginActionRequest) returns (vibecare.plugin.v1.ViewDescriptor);
}
```
(with `PluginSummary{id,name,icon,ui_kind,ui_entry,status}`, `ListPluginsResponse{repeated PluginSummary plugins}`, `RenderPluginViewRequest{plugin_id,view_id,params}`, `InvokePluginActionRequest{plugin_id,view_id,action,params}`). Import the plugin proto.

- [ ] **Step 1: Add proto + `just proto-gen` + `go build ./...`.**
- [ ] **Step 2: Failing test.** With a Registry holding a stub plugin: `ListPlugins` returns it; `RenderPluginView` proxies and returns the stub's ViewDescriptor; `InvokePluginAction` proxies. Run → FAIL.
- [ ] **Step 3: Implement** the service (thin proxy to `Registry.Client(id).RenderView/InvokeAction`; `ListPlugins` from `Registry.List()`). Register in `server.go`. Wire Registry+HostService in `main.go` (serve HostService on the gRPC server too, or a dedicated localhost listener — reuse the main gRPC server for simplicity).
- [ ] **Step 4: Run tests + `go build ./...`** → PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(api): PluginHostService proxies list/render/invoke"`

---

### Task 6: Go plugin SDK

**Files:**
- Create: `backend/pkg/pluginsdk/plugin.go` (serve loop + lifecycle)
- Create: `backend/pkg/pluginsdk/view.go` (view builder helpers)
- Test: `backend/pkg/pluginsdk/plugin_test.go`

**Interfaces:**
- Produces:
  - `func New() *Plugin` (reads `manifest.yaml` from cwd, parses `--host` flag).
  - `func (p *Plugin) OnAction(name string, fn func(Ctx, map[string]string) error)`
  - `func (p *Plugin) OnRender(viewID string, fn func(Ctx) View)`
  - `func (p *Plugin) Run() error` (prints its listen addr to stdout line 1, serves `PluginService`, dials host from `--host`, handles GetManifest/Initialize/ExecuteAction/InvokeAction/RenderView/HealthCheck).
  - `type Ctx struct { Host *HostClient }`; `HostClient` wraps `Store(collection,key string, v any) error`, `Query(collection string) ([]Record, error)`, `Notify(title,msg string)`, `Emit(type string, payload map[string]string)`.
  - View builders in `view.go`: `List(children ...Node) View`, `Row(children ...Node) Node`, `Text(s string) Node`, `Toggle(on bool, action, id string) Node`, `TextField(placeholder, action string) Node`, `Button(label, action string) Node`. `View`/`Node` convert to `pb.ViewDescriptor`/`pb.Node`.

- [ ] **Step 1: Failing test (view builders).** `List(Row(Text("a"), Toggle(true,"complete_todo","1")))` → a `pb.ViewDescriptor` with the expected node tree. Run → FAIL. Implement `view.go`. PASS.
- [ ] **Step 2: Failing test (serve loop).** Start a `Plugin` with an `OnRender` returning a fixed view + an `OnAction`; connect a `PluginServiceClient`; assert `RenderView` returns the view and `InvokeAction`/`ExecuteAction` invokes the handler. Use a fake host (in-process HostServer) for `Ctx.Host`. Run → FAIL. Implement `plugin.go`. PASS.
- [ ] **Step 3: Commit.** `git commit -am "feat(pluginsdk): serve loop, host client, view builders"`

---

### Task 7: Todos plugin (reference) + end-to-end

**Files:**
- Create: `backend/cmd/plugin-todos/main.go`
- Create: `backend/cmd/plugin-todos/manifest.yaml`
- Modify: `Justfile` (add `build-todos-plugin` + install to `~/.vibecare/plugins/todos/`)
- Test: `backend/cmd/plugin-todos/main_test.go`

**Interfaces:**
- Consumes: `pluginsdk` (Task 6).

- [ ] **Step 1: Write the plugin.** `main.go` (the whole thing):

```go
func main() {
    p := pluginsdk.New()
    p.OnAction("add_todo", func(c pluginsdk.Ctx, in map[string]string) error {
        return c.Host.Store("todos", newID(), map[string]any{"text": in["text"], "done": false})
    })
    p.OnAction("complete_todo", func(c pluginsdk.Ctx, in map[string]string) error {
        return c.Host.Store("todos", in["id"], map[string]any{"text": in["text"], "done": true})
    })
    p.OnAction("delete_todo", func(c pluginsdk.Ctx, in map[string]string) error {
        return c.Host.Delete("todos", in["id"]) // add Delete to HostClient/HostService if missing
    })
    p.OnRender("main", func(c pluginsdk.Ctx) pluginsdk.View {
        recs, _ := c.Host.Query("todos")
        rows := []pluginsdk.Node{pluginsdk.Row(pluginsdk.TextField("New todo…", "add_todo"))}
        for _, r := range recs {
            t := r.AsMap()
            rows = append(rows, pluginsdk.Row(
                pluginsdk.Toggle(t["done"].(bool), "complete_todo", r.Key),
                pluginsdk.Text(t["text"].(string)),
                pluginsdk.Button("✕", "delete_todo"),
            ))
        }
        return pluginsdk.List(rows...)
    })
    log.Fatal(p.Run())
}
```
(If `Delete` isn't in the Host contract yet, add `rpc DeleteData(DeleteRequest)` in Task 1's contract scope and `HostClient.Delete`/storage `DeletePluginData` — small, do it here and note it.)

- [ ] **Step 2: manifest.yaml** with id `com.vibecare.todos`, `exec: ./plugin-todos`, actions `[add_todo,complete_todo,delete_todo]`, `data: [todos]`, `ui_kind: shell-native`, `ui_entry: main`.
- [ ] **Step 3: Justfile target** to build the binary and copy binary+manifest to `~/.vibecare/plugins/todos/`.
- [ ] **Step 4: End-to-end test.** Boot Core with the plugin dir pointed at a temp dir containing the built todos plugin; via `PluginHostService`: `ListPlugins` shows Todos "ready"; `InvokePluginAction(add_todo,{text:"buy milk"})` then `RenderPluginView(main)` shows a row "buy milk"; restart Core → still there. Run → PASS.
- [ ] **Step 5: Commit.** `git commit -am "feat(plugins): todos reference plugin + e2e"`

---

### Task 8: Client — Plugins section + service wrapper (Swift)

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Services/PluginService.swift`
- Modify: `clients/.../Views/Dashboard/Sidebar.swift` (add `.plugins` case), `DashboardState.swift` (add `selectedPluginId`), `Dashboard.swift` (switch branches)
- Create: `clients/.../Views/Plugins/PluginListView.swift`

**Interfaces:**
- Consumes: generated `VCPluginHostService` Swift client (from `just proto-gen`).
- Produces: `struct PluginSummary { id, name, icon, uiKind, uiEntry, status }`; `PluginService.listPlugins() async -> [PluginSummary]`; `renderView(pluginId, viewId) async -> ViewDescriptor`; `invoke(pluginId, viewId, action, params) async -> ViewDescriptor`.

- [ ] **Step 1: `just proto-gen`** to regenerate Swift stubs including `VCPluginHostService`. Build the app: `just swift-build`.
- [ ] **Step 2: PluginService.swift** — thin wrapper mirroring existing `ActionService` pattern (use `GRPCClientManager.withXServiceClient`; add `withPluginHostServiceClient`). Map proto → local structs.
- [ ] **Step 3: Sidebar/Dashboard wiring** — add `.plugins` to `SidebarItem` (icon "puzzlepiece"), a `selectedPluginId` on `DashboardState`, and content/detail branches: selecting Plugins shows `PluginListView` (calls `listPlugins`), selecting a plugin shows `PluginScreen` (Task 9).
- [ ] **Step 4: Verify** — `just swift-run`, backend running with todos installed; confirm "Plugins → Todos" appears. Commit: `git commit -am "feat(client): Plugins sidebar + PluginService wrapper"`

---

### Task 9: Client — native declarative renderer (Swift)

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginRenderer.swift`
- Create: `clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginScreen.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/PluginRendererTests.swift`

**Interfaces:**
- Consumes: `ViewDescriptor`/`Node` structs, `PluginService` (Task 8).
- Produces: `PluginRenderer.render(_ node: Node, invoke: @escaping (action,params)->Void) -> AnyView`; `PluginScreen(pluginId, viewId)` that loads via `renderView`, renders, and on interaction calls `invoke` then swaps in the returned descriptor.

- [ ] **Step 1: Renderer.** `PluginRenderer` maps each node kind to SwiftUI: `list`→`List`/`VStack`, `row`→`HStack`, `text`→`Text`, `toggle`→`Toggle` (onChange → invoke `action` with `params`), `textField`→`TextField` (onSubmit → invoke with `{text}`), `button`→`Button` (tap → invoke), `spacer`→`Spacer`.
- [ ] **Step 2: PluginScreen.** `@State var descriptor`; `.task { descriptor = await service.renderView(...) }`; renders root nodes; passes an `invoke` closure that calls `service.invoke(...)` and assigns the returned descriptor (whole-view refresh — matches v1 no-diff model).
- [ ] **Step 3: Test.** Unit-test `PluginRenderer` produces the right view type per node kind (or a lightweight snapshot). Manually verify: add/complete/delete a todo in the running app and see it update + persist.
- [ ] **Step 4: Commit.** `git commit -am "feat(client): native declarative plugin renderer + todos screen"`

---

## Self-Review

- **Spec coverage:** contract (T1), storage (T2), HostService (T3), registry/supervisor (T4), app-facing proxy (T5), SDK (T6), todos + e2e (T7), client list + renderer (T8–T9). Registries: v1 uses the Registry itself as the plugin/UI registry and keeps the existing `ActionType`/`SidebarItem` enums (the enum→registry migration is explicitly a later slice per the spec) — the `.plugins` sidebar case is the interim seam. Covered.
- **Deferred by design (not gaps):** web/native UI tiers, sandboxing, distribution registry, event-type registry — all later slices per Spec 1.
- **Type consistency:** `ViewDescriptor`/`Node`, `PluginInfo`/`PluginSummary`, `HostClient.Store/Query/Delete`, `renderView`/`invoke` names are consistent across tasks. `Delete` path is introduced explicitly in T7 with a note to backfill the contract.
- **Simplicity check (per user):** one Go module, injectable seams for tests, whole-view refresh (no diffing), minimal node vocabulary, no sandbox. Kept intentionally small.
