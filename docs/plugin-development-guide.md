# VibeCare Plugin Development Guide (v1)

> **⚠️ Superseded — describes plugin system v1, which no longer exists.**
> v1 plugins were stateless and stored data through Core; v2 plugins own their own data
> directory, and Core never calls into a plugin. See
> [`docs/plugin-architecture.md`](plugin-architecture.md) for the current architecture.
> Kept as a historical record of how the design got here.

> Practical guide for building a VibeCare plugin. Written for future contributors and agents.
> Status: **v1 (Spec 1) shipped** — will evolve as we add plugins and later slices.
> Companions: [design spec](superpowers/specs/2026-08-06-plugin-system-v1-design.md) ·
> [decision log](plugin-system-decisions.md) · [architecture findings](plugin-architecture-findings.md).

## The 60-second model

- A **plugin is a standalone process** (any language; v1 ships a **Go SDK**) that speaks a small
  **gRPC contract**. It is **trusted** — no sandbox in v1.
- The plugin is **stateless**: it stores/reads its data through **Core** (the "host"), which owns
  a SQLite table. Core also owns scheduling, notifications, the event bus, and the UI shell.
- The plugin's **UI is server-driven**: it returns a **declarative view descriptor**; the
  Swift client renders it **natively in SwiftUI** (no webview, no per-platform UI code).
- **Core is the only thing that talks to plugins.** The client talks to Core; Core proxies.

```
Client (SwiftUI)  ──►  Core (kernel)  ──►  Plugin process (your code)
  Plugins sidebar       PluginRegistry       PluginService: GetManifest/Initialize/
  native renderer  ◄──  proxy Render/Invoke     RenderView/InvokeAction/ExecuteAction/Health
                        HostService      ◄──  Plugin calls back: Store/Query/Delete/Notify/Emit/Log
                        SQLite plugin_data
```

## Anatomy of a plugin

A plugin is **two files**: a `manifest.yaml` and a Go `main.go`. The reference `todos` plugin
(`backend/cmd/plugin-todos/`) is ~100 lines total. Copy it as your starting point.

### `manifest.yaml`
```yaml
id: com.vibecare.todos        # unique, reverse-DNS
name: Todos                   # shown in the Plugins sidebar
version: 0.1.0
icon: checklist               # SF Symbol-ish name (client maps it)
exec: ./plugin-todos          # binary Core launches, RELATIVE to this manifest's dir
provides:
  actions: [add_todo, complete_todo, delete_todo]  # action ids you OnAction()
  events: []                  # event types you Emit() (no-op in v1)
  data: [todos]               # storage collections you own
ui:
  kind: shell-native          # v1: rendered by the Swift shell. reserved: web | native
  entry: main                 # the view id the client asks RenderView() for first
```

### `main.go` (the whole plugin, using the SDK)
```go
package main

import (
    "github.com/google/uuid"
    "github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

func main() {
    p := pluginsdk.New() // reads ./manifest.yaml, parses --host <addr> from Core

    p.OnAction("add_todo", func(c pluginsdk.Ctx, in map[string]string) error {
        return c.Host.Store("todos", uuid.NewString(),
            map[string]any{"text": in["text"], "done": false})
    })
    p.OnAction("delete_todo", func(c pluginsdk.Ctx, in map[string]string) error {
        return c.Host.Delete("todos", in["id"])
    })

    p.OnRender("main", func(c pluginsdk.Ctx) pluginsdk.View {
        recs, _ := c.Host.Query("todos")
        rows := []pluginsdk.Node{
            pluginsdk.Row(pluginsdk.TextField("New todo…", "add_todo")),
        }
        for _, r := range recs {
            m, _ := r.AsMap()
            done, _ := m["done"].(bool)
            text, _ := m["text"].(string)
            rows = append(rows, pluginsdk.Row(
                pluginsdk.Toggle(done, "complete_todo", r.Key), // id → params["id"]
                pluginsdk.Text(text),
                pluginsdk.Button("✕", "delete_todo", r.Key),    // id → params["id"]
            ))
        }
        return pluginsdk.List(rows...)
    })

    p.Run() // serves gRPC, prints its listen addr, blocks until Core stops it
}
```

## SDK reference (`backend/pkg/pluginsdk`)

**Lifecycle**
- `pluginsdk.New() *Plugin` — reads `manifest.yaml` from the working dir, parses `--host`.
- `(*Plugin).OnAction(name string, fn func(Ctx, map[string]string) error)` — handle an action.
- `(*Plugin).OnRender(viewID string, fn func(Ctx) View)` — build a view descriptor.
- `(*Plugin).Run() error` — serve + block. **The SDK owns stdout** (see gotchas).

**Host callbacks** — `Ctx{ Host *HostClient }`:
- `Store(collection, key string, v any) error` — JSON-marshals `v` and upserts.
- `Query(collection string) ([]Record, error)` — all records in a collection.
- `Delete(collection, key string) error`
- `Notify(title, message string) error`
- `Emit(eventType string, payload map[string]string) error` — **no-op in v1** (event
  wire-propagation not built yet).
- `Record{ Key, ValueJSON string }`; `(Record).AsMap() (map[string]any, error)`.

**View builders** (→ the declarative UI the shell renders natively):
- `List(children ...Node) View` — the root container.
- `Row(children ...Node) Node`
- `Text(s string) Node`
- `Toggle(on bool, action, id string) Node` — flips → `InvokeAction(action, {id})`.
- `TextField(placeholder, action string) Node` — submit → `InvokeAction(action, {text: entered})`.
- `Button(label, action string, id ...string) Node` — tap → `InvokeAction(action, {id})`.
- Node kinds understood by the renderer: `list, row, text, toggle, textField, button, spacer`
  (`spacer` has no builder helper yet — construct a `Node{Kind:"spacer"}` if needed).

**Interaction model:** interactions carry data back via `params`. `Toggle`/`Button` put their
item id in `params["id"]`; `TextField` puts the typed value in `params["text"]`. After any
`InvokeAction`, the SDK **re-renders the whole view** (`OnRender` for that view id) and returns
the fresh descriptor — the client swaps it in wholesale (no diffing in v1). Keep renders cheap.

## Build, install, run

Plugins are discovered from **`~/.vibecare/plugins/<id>/`** (one folder per plugin: the binary
+ `manifest.yaml`). Model the build recipe on `build-todos-plugin` in the `Justfile`:
```
just build-todos-plugin   # go build → copies binary + manifest into ~/.vibecare/plugins/todos/
just dev                  # stops the launchd backend, runs the plugin-aware dev backend
```
- Use **`just dev`**, not `just run` — the always-on backend is a launchd service
  (`io.vibecare.server`) holding :50051/:8080; `just dev` frees the ports and restores the
  service on exit. To make a local plugin-aware build the *persistent* backend, `just deploy-local`.
- **Discovery happens once, at Core startup.** After installing/updating a plugin you must
  **restart Core** (Ctrl-C `just dev`, run it again). Plugins are not hot-reloaded.
- Watch Core's startup logs: the registry logs each plugin it launches + marks `ready`, or logs
  a **warning** and skips it (bad manifest, launch failure, handshake failure) — that warning is
  your first debugging clue.

## Where plugin data lives

Core's SQLite DB `~/.vibecare/vibecare.db`, table **`plugin_data`**:
`(plugin_id, collection, key, value_json, updated_at)`, PK `(plugin_id, collection, key)`.
Browse it: `just inspect-db` → `SELECT * FROM plugin_data WHERE collection='todos';`
Because data is backend-owned, it survives client/app restarts and is the same for any client
that connects to this Core.

## Constraints & gotchas (read these)

- **Trusted, no sandbox** — a plugin runs with your user's privileges. Only install code you trust.
- **⚠️ ONE plugin at a time (v1).** Production doesn't yet attribute a plugin's callbacks to its
  id, so all plugins would share the empty `plugin_id` namespace. The registry therefore
  **refuses to load a 2nd distinct plugin** (you'll see a Warn). **Wiring per-plugin namespacing
  is the required first task before any 2nd plugin ships** — see Roadmap.
- **Never write to stdout from your plugin.** The SDK prints exactly one line (its listen
  address) that Core reads; Core does not drain further stdout, so extra writes will hang your
  plugin. Log to **stderr** (Go's `log` default is stderr).
- **Plugins are stateless** — never hold important state in memory; persist via `Host.Store`.
- **Whole-view refresh** — every interaction re-renders the whole view; don't rely on local UI
  state surviving a round-trip.
- **Client is macOS 15+**; the shell renders your descriptor natively — you get consistency for
  free but can only use the node kinds above (extend the vocabulary in the SDK + renderer if you
  need more).
- Changing the plugin **contract** (`proto/vibecare_plugin.proto`) requires `just proto-gen` and
  touches both Go and Swift. Adding a *plugin* does **not** need proto changes.

## Steps to add a NEW plugin (checklist for future agents)

1. `cp -r backend/cmd/plugin-todos backend/cmd/plugin-<name>`; rewrite `main.go` handlers/renders.
2. Edit `manifest.yaml`: new `id`, `name`, `icon`, `exec: ./plugin-<name>`, `provides`, `ui`.
3. Add a `just build-<name>-plugin` recipe (mirror `build-todos-plugin`) that builds + installs
   to `~/.vibecare/plugins/<id>/`.
4. If you changed the contract, `just proto-gen`; otherwise skip.
5. `just build-<name>-plugin`, then **restart Core** (`just dev`).
6. **Remember the single-plugin guard:** your new plugin only loads if it's the *only* one
   installed — until namespacing is wired, remove/rename `~/.vibecare/plugins/todos/` to test a
   different plugin, or (better) do the namespacing wiring first.
7. Verify in the app: sidebar → **Plugins** → your plugin renders and its actions persist.

## Roadmap (not built yet — each its own spec → plan → build)

1. **Per-plugin namespacing wiring** (SDK sends its id as gRPC metadata + a host interceptor, or
   a dedicated per-plugin host listener). **Unblocks multiple plugins** — do this first.
2. Web UI tier (`ui.kind: web`, embedded webview) for richer/independent UIs.
3. Native-module UI tier (`ui.kind: native`, in-process per-platform bundle).
4. Native providers (activity-watch, vibecheck) — same contract, native processes with
   hardware/OS access.
5. Downloadable registry + signing/publishing (today discovery = the local folder).

Known v1 limitations are tracked in the design spec's "Known Limitations (v1)" section.

## Codebase map

| Piece | Path |
|---|---|
| Plugin gRPC contract | `proto/vibecare_plugin.proto` |
| Go plugin SDK | `backend/pkg/pluginsdk/` (`plugin.go`, `view.go`) |
| Reference plugin | `backend/cmd/plugin-todos/` |
| Host callbacks (Store/Query/Delete/Notify/Emit/Log) | `backend/internal/plugins/host_service.go` |
| Registry + subprocess supervisor + single-plugin guard | `backend/internal/plugins/registry.go`, `manifest.go` |
| Generic storage | `backend/internal/storage/plugin_data.go` (+ migration) |
| App-facing proxy (client ↔ Core) | `backend/internal/api/plugin_host_service.go` |
| Wiring (registry/host startup) | `backend/cmd/server/main.go` |
| Client: Plugins sidebar + service | `clients/macos-swift/VibeCare/vibecare/Views/Plugins/`, `Services/PluginService.swift` |
| Client: native declarative renderer | `clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginRenderer.swift` |
