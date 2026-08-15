# CLAUDE.md

## Project Overview

VibeCare is a wellness and routine management mono-repo:
- **Backend**: Go + gRPC + SQLite + RRule scheduling (`backend/`)
- **Client**: Native SwiftUI macOS app (`clients/macos-swift/VibeCare/`)
- **CLI/TUI**: Go terminal client for debugging and scripting (`clients/cli/`)
- **Protocol**: Protobuf definitions in `proto/vibecare.proto` (source of truth for API contract)
- **Build Tool**: [Just](https://github.com/casey/just) command runner

## Essential Commands

```bash
just setup              # First-time: install deps, proto-gen, migrate
just run                # Start backend (gRPC :50051 + HTTP :8080)
just test               # Backend tests
just proto-gen          # Regenerate protobuf for backend + Swift
just swift-build        # Build Swift client
just swift-run          # Run Swift client
just swift-test         # Swift tests
just cli-build          # Build CLI client -> bin/vibecare
just cli-run ARGS       # Run CLI client (no args = TUI)
just cli-test           # CLI tests
just cli-install        # Install vibecare into $GOBIN
just migrate            # Run DB migrations
just new-migration NAME # Create new migration
just inspect-db         # Open litecli for ~/.vibecare/vibecare.db
just docs-setup         # One-time: install docs-site deps + pandoc
just docs               # Serve docs/ as a Starlight site (http://localhost:4321)
just build-plugins      # Build every plugin binary into its own directory
```

## Mono-Repo Conventions

### Proto changes touch both sides
When modifying `proto/vibecare.proto`:
1. Run `just proto-gen` (generates backend + Swift stubs)
2. Update backend service implementation in `backend/internal/api/`
3. Update Swift service wrapper in `clients/macos-swift/VibeCare/vibecare/Services/`

### Generated code - do not edit
- `backend/pkg/proto/` — Go stubs
- `clients/macos-swift/VibeCare/VCStubs/` — Swift stubs

### Database migrations use Goose (not go-migrate)
```bash
just new-migration add_foo_column  # creates SQL file
just migrate                        # applies it
```

### Plugins are independent subprocesses (v2)

A plugin is a directory under `plugins/<id>/` with a `manifest.yaml` and a
binary. Core discovers it at startup, spawns it, and reverse-proxies its
HTTP UI at `/p/<id>/`. Adding a plugin requires **no change to core and no
client release** — see
[`docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md`](docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md).

- Plugin↔core contract: `proto/plugin/v1/plugin.proto` (3 RPCs, plugin is always the client)
- Client↔core contract: `proto/client/v1/client.proto` (2 RPCs, frozen)
- SDK: `backend/pkg/vc` — `vc.Connect()` is the whole entry point
- Reference plugin: `plugins/todo/`
- Kernel: `backend/kernel/` — contains zero product semantics, enforced by `TestKernelContainsNoProductNouns`
- Plugin state lives in `~/.vibecare/data/<id>/`; cross-plugin communication is bus topics only, never the filesystem
- Default plugins directory: `~/.vibecare/plugins-v2/` in production; `just run` overrides it with `--plugins-dir ../plugins`, scanning this repo's own `plugins/` instead — deliberately not the v1 `~/.vibecare/plugins/` directory, whose manifests use ids the v2 regex rejects

## Gotchas

- Default ports: gRPC `50051`, HTTP `8080`
- DB location: `~/.vibecare/vibecare.db`
- Scheduler polls every 1 minute for due schedules
- Swift client requires macOS 15+
- Swift client has **no local persistence** — all data comes from backend via gRPC
- Actions are linked to schedules via a join table (`schedule_actions`), not embedded
- `clients/cli/` is its own Go module (like `plugins/vibecheck/`), so the backend's `go build ./...` does not reach it — use `just cli-build` / `just cli-test`
- The CLI's `--json` output is a versioned contract, not pretty-printing: the struct tags in `clients/cli/internal/vc/types.go` **are** the schema, and renaming a field means bumping `ContractVersion`

## Component Documentation

Each component has its own CLAUDE.md with conventions and patterns:
- [`backend/CLAUDE.md`](backend/CLAUDE.md) — Go backend specifics
- [`clients/macos-swift/VibeCare/CLAUDE.md`](clients/macos-swift/VibeCare/CLAUDE.md) — Swift client specifics
- [`clients/cli/README.md`](clients/cli/README.md) — CLI/TUI client: command surface, `--json` contract, exit codes, TUI keys

For deeper architecture details, see [`docs/architecture.md`](docs/architecture.md).
For MCP server setup, see [`docs/MCP_SETUP.md`](docs/MCP_SETUP.md).
