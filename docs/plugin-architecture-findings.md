# VibeCare Architecture Findings — Toward a Plugin System

> **⚠️ Superseded — describes plugin system v1, which no longer exists.**
> v1 plugins were stateless and stored data through Core; v2 plugins own their own data
> directory, and Core never calls into a plugin. See
> [`docs/plugin-architecture.md`](plugin-architecture.md) for the current architecture.
> Kept as a historical record of how the design got here.

> Snapshot of the current architecture as it exists on `feat/system-power-actions`,
> written to inform the design of a plugin system. Date: 2026-08-06.
> This is a *findings* doc (what is), not a design doc (what will be).

## TL;DR

VibeCare today is a **schedule → event → action** pipeline:

1. Backend scheduler polls SQLite for due schedules.
2. On a due schedule it emits a `DispatchEvent` (gRPC server-stream) carrying `ActionIds`.
3. The **client** (macOS app) receives the event, fetches the action definitions, and
   **executes them locally** (notification, lock screen, open link, …).

The backend is a **coordinator/store**, not an executor. Action *behavior* lives on the
client. This shape is important: a "plugin" in VibeCare is potentially three things at
once — a backend capability, a client behavior, and a UI surface — and the current
architecture has **no registry** for any of them. Everything is a closed enum + exhaustive
`switch`, duplicated across proto, Go, and Swift.

---

## The four surfaces

### 1. Protobuf contract (`proto/vibecare.proto`)

- Single file, `proto3`, package `vibecare.v1`, `go_package` + `swift_prefix = "VC"`.
- **7 services**: `ProfileService`, `RoutineService`, `ScheduleService`, `ActionService`,
  `EventService` (only streaming RPC), `ScheduleTemplateService`, `IconService`.
- Domain: `Profile` 1:N `Routine`/`Action`/`Schedule`; `Routine` 1:N `Schedule`;
  `Schedule` N:M `Action` via the **`schedule_actions` join table** (ordered).
- **`ActionType` enum** (closed, values 1–8): `NOTIFICATION, OPEN_LINK, SEND_EMAIL,
  RUN_SCRIPT, PLAY_SOUND, SYSTEM_COMMAND, API_CALL, LOG_ENTRY`.
- `Action.parameters` is a free-form `map<string,string>` — the one open-ended seam.
- `ActionService` has self-describing metadata RPCs (`ListActionTypes`,
  `GetActionParameters`, `ValidateAction`) — **intended** as an action-type registry, but
  currently stubbed/hardcoded (only Notification + Open Link returned).

### 2. Go backend (`backend/`)

- Manual constructor DI in `cmd/server/main.go`. No framework.
- gRPC services all hang off one `Server` struct; wired in `internal/api/server.go`
  `RegisterServices()` — **the central registration seam**.
- Scheduler (`internal/scheduler/scheduler.go`) polls every 10s, compares precomputed
  `NextExecution`, and `dispatchScheduleEvent()` broadcasts via the in-memory `EventHub`
  pub/sub (`event_hub.go`, keyed by profileID).
- **Backend does NOT execute actions.** `ExecuteAction`, `ValidateAction`,
  `GetActionParameters`, `ListActionTypes` are TODO stubs / hardcoded.
- `internal/actions/` is an **empty reserved package** — the obvious home for an
  executor/registry.
- Storage is concrete `*storage.DB` (SQLite, WAL, goose migrations, single conn). Only the
  MCP layer abstracts it behind an interface.
- **Closed `ActionType`** duplicated in `models.go` + proto + two switch converters. Adding
  a type = edit proto + both enums + both switches.

### 3. macOS Swift client (`clients/macos-swift/VibeCare/`)

- SPM: `VCStubs` (generated) + `VibeCare` (monolithic app target, macOS 15+).
- Classic MVVM: `ObservableObject` + `@Published`, no `@Observable`, **no local persistence**
  (all state from backend each launch).
- UI: hybrid main window (`NavigationSplitView`, 3-column) + `MenuBarExtra` + Settings window.
- **Navigation is a closed enum** `SidebarItem {.schedules,.routines,.actions,.settings}`
  driving exhaustive `switch`es in `Dashboard.swift` (content/detail/toolbar/add/count).
  Adding a feature screen today = manual edits at ~5 sites. **No registry.**
- gRPC: `GRPCClientManager` with one `withXServiceClient` closure per service (fresh
  connection per call, no pool). `EventService` opens the server-stream and dispatches.
- **Action execution seam**: `EventService.executeAction(_:for:)` `switch`es on
  `action.type` → handler singletons (`NotificationManager`, `LinkHandler`,
  `SystemCommandHandler`). `runScript`/`sendEmail`/`playSound`/`apiCall` are TODO no-ops.
- **Best existing "plugin-shaped" pattern**: `ActionType.requiredParameters:
  [ActionParameter]` — each action type self-describes its params (name/type/required/
  allowedValues/default), and `ActionParametersView` renders a **generic editor from
  metadata** (dropdowns for `allowedValues`, etc.). This is declarative params → generic UI
  → typed handler. But it's closed (fixed enum, compile-time switch).
- System-command work (`feat/system-power-actions`): platform-neutral vocabulary
  (`lock/sleep/...`), countdown overlay state machine, screen lock via private
  `login.framework` symbol, injectable `CommandRunner`/`ScreenLocker` seams for testing.

### 4. MCP server (`backend/internal/mcp/`, Go)

- Standalone binary (`cmd/mcp-server`) + embeddable in backend. Transports: stdio +
  streamable HTTP (`:8081/mcp`). Scoped to one `profileID`.
- Talks to backend via **`Storage` interface** (`storage_interface.go`) — the cleanest
  abstraction in the repo — with a gRPC-client adapter and a direct-DB adapter.
- 15 tools (routine/schedule/action CRUD + `execute_routine`), resolve by name for the LLM.
  Read-only resources (`vibecare://routines`, etc.). Docs undercount tools; `tools.go` is
  source of truth.
- Only consumes Routine/Schedule/Action services. Profile/Event/Template/Icon unused.

---

## Where plugins would plug in (the seams)

| Seam | Location | State today |
|------|----------|-------------|
| Action-type registry | `ActionService.ListActionTypes/GetActionParameters/ValidateAction` | stubbed/hardcoded |
| Server-side executor | `internal/actions/` (empty), `action_service.go` `ExecuteAction` | not implemented |
| Client action dispatch | `EventService.executeAction` switch | closed switch |
| Client param UI | `ActionType.requiredParameters` → `ActionParametersView` | declarative but closed enum |
| Client navigation | `SidebarItem` enum + `Dashboard` switches | closed, ~5 edit sites |
| gRPC service registration | `api.RegisterServices` | manual |
| Data-driven catalogs | `TemplateLoader`, `IconLoader` (JSON/SVG from disk) | loader pattern exists |
| Event fan-out | `EventHub` + `EventType` enum | in-memory pub/sub |
| MCP capability surface | `mcp.Storage` interface + `tools.go` registry | interface exists |

## Key tensions for the design

1. **A plugin spans up to 3 layers** (backend logic, client behavior, client UI) plus
   optionally MCP tools. What is the unit of a "plugin"? Does one plugin ship all layers, or
   are they independent?
2. **Closed enums everywhere.** The single biggest structural blocker: `ActionType` and
   `SidebarItem` are compile-time enums with exhaustive switches across three languages.
   Plugins need registries, not enums.
3. **Where does plugin code run?** Backend is Go, client is Swift. In-process plugins mean
   recompiling the host. Out-of-process (subprocess / gRPC / WASM / MCP-style) means a
   protocol. This is the central architectural fork.
4. **Existing good bones**: the metadata-driven `ActionType.requiredParameters` → generic UI
   pattern, and the `mcp.Storage` interface, are the two patterns most worth generalizing.
