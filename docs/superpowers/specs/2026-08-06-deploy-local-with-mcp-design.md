# Deploy Local Build with Always-On MCP

**Date:** 2026-08-06
**Status:** Approved

## Problem

`deploy-local` swaps the always-on `io.vibecare.server` LaunchAgent to the developer's
local build (gRPC `50051` + HTTP `8080`). There is no equivalent for the MCP server:
to get MCP you run `just run-with-mcp PROFILE_ID` or `just mcp-start-http-server` by
hand, in the foreground, and you must look up the profile ID yourself.

A naive "bake `--with-mcp` into `io.vibecare.server`" does **not** work: embedded
`--with-mcp` only starts a **STDIO** transport (`main.go` `mcp.NewSTDIOTransport`). Under
launchd the daemon's stdin is `/dev/null`, so the transport never receives a request, and
STDIO clients (Claude Desktop) spawn the process themselves — they cannot attach to a
running daemon. The web server exposes only `/api/mcp/tools` (read-only introspection),
not a protocol endpoint. The connectable MCP transport lives solely in the standalone
`cmd/mcp-server --http` (`runHTTPMode`, serves `/mcp`).

## Decision

Add `deploy-local-with-mcp` — the MCP counterpart to `deploy-local`. It picks a profile
interactively, builds the **standalone** MCP binary, and bakes it into its own always-on
LaunchAgent `io.vibecare.mcp` running in **HTTP** mode. This is "deploy-local, but for
MCP", using the transport that actually works.

## Recipe (Justfile, `🤖 MCP Server` group)

```
deploy-local-with-mcp profile_id="" port="8081"
```

Bash recipe, `set -euo pipefail`, no sudo:

1. **Guard** — `~/.vibecare/vibecare.db` exists, else error → `just migrate`.
2. **Profile picker** — if `profile_id` is empty, list profiles from SQLite as a numbered
   menu (name + email), read and validate the selection (same style as `mcp-configure`).
   Zero profiles → error pointing to `just grpc-create-profile`. A passed `profile_id`
   skips the prompt.
3. **gRPC warning** — if port `50051` is free, print a note to run `just deploy-local` /
   `just service-start` first. Do not hard-fail; `KeepAlive` recovers once gRPC is up.
4. **Build** — `go build -ldflags="-s -w" -o ../bin/vibecare-mcp-server cmd/mcp-server/main.go`
   → copy to `~/.local/bin/vibecare-mcp-server`.
5. **Write LaunchAgent** — (re)generate `~/Library/LaunchAgents/io.vibecare.mcp.plist`
   every run (the profile arg varies, so regeneration is the idempotent choice), mirroring
   the server plist: `KeepAlive{SuccessfulExit=false}`, `RunAtLoad`, `ProcessType=Background`,
   `ThrottleInterval=30`, logs to `~/.vibecare/logs/mcp.log` / `mcp-error.log`, absolute
   `$HOME` paths. `ProgramArguments`:
   ```
   ~/.local/bin/vibecare-mcp-server --http --profile-id=<picked> --grpc-addr localhost:50051 --port <port>
   ```
   `--grpc-addr` is passed explicitly so the daemon does not depend on `~/.vibecare/config.yaml`.
6. **Reload** — `just _reload-service io.vibecare.mcp`.
7. **Print** — success + Claude Desktop snippet (`mcp-remote http://localhost:<port>/mcp`).

## Targeted refactor (DRY)

Parametrize the existing private `_reload-service` recipe:

```
_reload-service label="io.vibecare.server":
```

Its body already derives `plist` from `$label`, so existing callers (`deploy-local`,
`dev`, `service-start`) keep working via the default, and the new recipe passes
`io.vibecare.mcp`.

## Constraints

- Use `launchctl bootout` / `bootstrap` / `kickstart` via `gui/$(id -u)/io.vibecare.mcp`;
  never `kill` (KeepAlive revives it).
- Plists need absolute paths (expand `$HOME`, not `~`).
- Idempotent and safe on a fresh machine (regenerate plist, reload).

## Out of scope

`mcp-service-status/stop/start`, a `scripts/io.vibecare.mcp.plist` repo/PKG template,
`service-restore-prod` for MCP, and any change to embedded `--with-mcp`.
