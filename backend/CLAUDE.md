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
└── pkg/proto/                 # Generated protobuf stubs (do not edit)
```

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

For full architecture details, see [`docs/architecture.md`](../docs/architecture.md).
