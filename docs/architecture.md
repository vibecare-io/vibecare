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
