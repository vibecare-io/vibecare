# VibeCare Architecture

## System Overview

```
┌──────────────────────┐         gRPC (protobuf)        ┌──────────────────────┐
│   Swift macOS App    │ ◄─────────────────────────────►│    Go Backend        │
│   (SwiftUI + MVVM)   │                                │                      │
│                      │         HTTP (icons, web)      │  ┌────────────────┐  │
│   No local storage   │ ◄────────────────────────────► │  │  gRPC Services │  │
│   In-memory state    │                                │  └───────┬────────┘  │
│                      │         SSE (events)           │          │           │
│   EventService       │ ◄──────────────────────────────│  ┌───────▼────────┐  │
└──────────────────────┘                                │  │ Storage (SQL)  │  │
                                                        │  └───────┬────────┘  │
                                                        │          │           │
                                                        │  ┌───────▼────────┐  │
                                                        │  │  SQLite DB     │  │
                                                        │  │  ~/.vibecare/  │  │
                                                        │  └────────────────┘  │
                                                        │                      │
                                                        │  ┌────────────────┐  │
                                                        │  │  Scheduler     │  │
                                                        │  │  (1-min poll)  │  │
                                                        │  └───────┬────────┘  │
                                                        │          │           │
                                                        │  ┌───────▼────────┐  │
                                                        │  │  EventHub      │  │
                                                        │  │  (SSE stream)  │  │
                                                        │  └────────────────┘  │
                                                        └──────────────────────┘
```

## Domain Model

Defined in `proto/vibecare.proto` (single source of truth):

| Entity | Purpose |
|--------|---------|
| **Profile** | User account with preferences and devices |
| **Routine** | Named collection — metadata container, actions linked via schedules |
| **Action** | Individual task: notification, open_link, run_script, api_call, display_message, system_command, log_entry, custom |
| **Schedule** | RRule-based recurring trigger (RFC 5545). Linked to actions via `schedule_actions` join table |
| **ExecutionLog** | Audit trail of routine executions |

### Relationships

```
Profile ──1:N──► Routine
Profile ──1:N──► Action
Profile ──1:N──► Schedule
Routine ──1:N──► Schedule
Schedule ──N:M──► Action  (via schedule_actions join table, with ordering)
```

## Data Flow

### CRUD Operations
```
User Action → SwiftUI View → ViewModel → Service → GRPCClientManager → Backend gRPC → Storage → SQLite
                                                                         │
                                          View ← @Published ← Service ◄─┘ (protobuf → Swift model)
```

### Real-Time Event Flow
```
Scheduler (polls DB every 1 min)
    → finds due schedules
    → EventHub broadcasts event
    → SSE stream to Swift client
    → EventService receives trigger
    → fetches actions from backend
    → executes locally (notification, open URL, run script, etc.)
```

## RRule Scheduling

Uses RFC 5545 recurrence rules. Examples:

```
FREQ=DAILY;INTERVAL=1;BYHOUR=9,18;BYMINUTE=0          # Daily at 9 AM and 6 PM
FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=14;BYMINUTE=0 # Weekdays at 2 PM
FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=10;BYMINUTE=0         # First of month at 10 AM
```

## Plugins

Full design: [`docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md`](superpowers/specs/2026-08-13-plugin-architecture-v2-design.md).

Plugins are independent, supervised subprocesses — not code linked into
Core or the client. A plugin is a directory under `plugins/<id>/` with a
`manifest.yaml` and a binary; Core's kernel (`backend/kernel/`) discovers,
spawns, and health-checks it at startup. `Discover` skips a malformed or
invalid manifest with a warn log and keeps going, but a duplicate plugin id
is a hard startup error. `Registry` (the kernel's in-memory plugin state)
exposes `CompareAndSetState` for writes derived from a previously-read
state, so concurrent supervisors don't clobber each other's transitions.

```
Core (kernel)                                Plugin subprocess
┌───────────────────────────┐  unix socket   ┌───────────────────────┐
│ ~/.vibecare/core.sock      │◄──────────────►│  vc.Connect()          │
│ 3 RPCs: Register/Publish/  │  (plugin is    │  (backend/pkg/vc)      │
│ Alert                      │   the client)  │                        │
└──────────┬──────────────────┘               └──────────┬─────────────┘
           │                                              │
           │ reverse proxy                                │ own HTTP server
           ▼                                              ▼
   <base_url>/p/<id>/ ───────────────────────────►  plugin's own web UI
```

- **Plugin↔core contract**: `proto/plugin/v1/plugin.proto` — three RPCs,
  the plugin is always the gRPC *client*, dialing Core over
  `~/.vibecare/core.sock`. Core never calls into a plugin.
- **Plugin UI**: each plugin serves its own HTTP UI; Core reverse-proxies
  it at `<base_url>/p/<id>/`. Plugins share one web origin, so a plugin's
  UI must not depend on `localStorage` (state that should survive a
  reload belongs in the plugin's own storage, via the SDK).
- **Client↔core contract**: `proto/client/v1/client.proto` — two RPCs.
  The Swift client gets a plugin roster and a stream of alerts; it
  contains no plugin-specific code. Plugin screens are `WKWebView`s
  pointed at Core's proxy path.
- **Core's dashboard**: `/_core/status`, for inspecting plugin health
  outside the client.
- **Default plugins directory**: in production, core scans
  `~/.vibecare/plugins-v2/`. In development, `just run` passes
  `--plugins-dir ../plugins`, so it scans the repo's own `plugins/`
  directory instead. This is deliberately *not* the v1
  `~/.vibecare/plugins/` directory — those manifests use ids that v2's
  stricter id regex rejects.
- **Known gap**: alert action buttons are carried on the wire
  (`plugin.proto`) and modeled on the client (`PluginAlert`), but are not
  yet rendered — the client presents title/body/level only. Rendering
  them is future work.

## Telemetry

- OpenTelemetry instrumentation on both backend and Swift client
- Backend: `otelgrpc` interceptors, OTLP exporter to `localhost:4317`
- Swift: view-level tracing via `ViewInstrumentation.swift`
- Jaeger UI: `http://localhost:16686`

## MCP Server

VibeCare exposes an MCP server for natural language interaction via Claude Desktop.
Two modes: embedded (`--with-mcp` flag) or standalone (`cmd/mcp-server/`).

Tools: `create_routine`, `list_routines`, `get_routine`, `delete_routine`, `create_schedule`, `list_schedules`, `delete_schedule`, `execute_routine`

Resources: `vibecare://routines`, `vibecare://schedules`, `vibecare://actions`, `vibecare://execution-logs`

See [`MCP_SETUP.md`](MCP_SETUP.md) for complete setup instructions.
