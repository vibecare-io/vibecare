# Backend — CLAUDE.md

Go gRPC server with SQLite storage and RRule-based scheduling.

## Entry Point

`cmd/server/main.go` — initializes gRPC server, HTTP web server, scheduler, and telemetry.

## Code Layout

```
backend/
├── cmd/server/main.go        # Main entry point
├── cmd/mcp-server/main.go    # Standalone MCP server
├── internal/
│   ├── api/                   # gRPC service implementations
│   │   └── server.go          # RegisterServices() — register new services here
│   ├── scheduler/             # Polls DB every minute, triggers events via EventHub
│   ├── storage/               # SQLite layer, one file per entity
│   │   └── migrations/        # Goose SQL migrations
│   └── telemetry/             # OpenTelemetry + Jaeger integration
├── kernel/                    # Plugin kernel: discovery, supervision, proxy, bus, dashboard
├── pkg/vc/                    # Plugin SDK (vc.Connect())
└── pkg/proto/                 # Generated protobuf stubs (do not edit)
```

### `backend/kernel/` is generic infrastructure

It contains zero product semantics — no mention of routines, schedules,
notifications, or any other VibeCare noun. This is enforced by
`TestKernelContainsNoProductNouns`; a change that adds a product-specific
concept there will fail that test. Product logic belongs in a plugin
(`plugins/<id>/`), not the kernel.

## Conventions

- **Adding a gRPC service**: Define in `proto/vibecare.proto` → `just proto-gen` → implement in `internal/api/` → register in `server.go:RegisterServices()`
- **Storage layer**: One file per entity in `internal/storage/` (e.g., `profile.go`, `routine.go`)
- **Migrations**: Goose with SQL files. `just new-migration NAME` to create, `just migrate` to apply
- **Logging**: Structured logging via zap to stdout
- **Tracing**: OpenTelemetry with `otelgrpc` interceptors. Jaeger UI at `http://localhost:16686`

## Testing

```bash
just test              # All tests
just test-coverage     # Coverage report (opens HTML)
just test-stack        # Integration: starts server + tests gRPC endpoints
just fmt               # Format code
just lint              # golangci-lint
```

## Gotchas

- EventHub uses SSE (server-sent events) for real-time client notifications
- RRule library follows RFC 5545 for recurring schedule calculations
- Tracing enabled by default (`--enable-tracing`), OTLP endpoint: `localhost:4317`
- MCP server can run embedded (`--with-mcp`) or standalone (`cmd/mcp-server/`)
- **One server per database.** Startup takes an exclusive `flock` on `<db>.lock`; a second
  server on the same database exits non-zero naming the holder's PID. To run one beside a
  live server use `--db <other path>` — a different `--port` is not enough, since both
  would still share `~/.vibecare/vibecare.db` and race over `next_execution`. Readers
  (`just inspect-db`, sqlite3) never take the lock. See
  [the design](../docs/superpowers/specs/2026-08-18-single-instance-db-lock-design.md).

For full architecture details, see [`docs/architecture.md`](../docs/architecture.md).
