# Local-Build Backend Workflow

**Date:** 2026-07-22
**Status:** Approved

## Problem

The PKG-installed backend runs as a launchd LaunchAgent (`io.vibecare.server`) with
`KeepAlive=true` and `RunAtLoad=true`. It holds gRPC `50051` + HTTP `8080` and uses
`~/.vibecare/vibecare.db`. During development `just run` (`go run …`) wants the same
ports and DB, so it conflicts with the always-on service — and a plain `kill` is
revived by launchd.

## Decision

One backend on the machine, always the developer's build. Repoint the installed
LaunchAgent from `/usr/local/bin/vibecare-server` (PKG, sudo) to
`~/.local/bin/vibecare-server` (developer build, no sudo). Provide `just` recipes for
the fast inner loop, for deploying a new build into the service, and for reverting to
the shipped binary.

## Recipes (Justfile, `📦 Build & Run` group)

- `deploy-local` — `go build -ldflags="-s -w"` → copy to `~/.local/bin/vibecare-server`
  → if the installed plist doesn't already point there, rewrite its binary path and
  `bootout`+`bootstrap`; otherwise `launchctl kickstart -k` to restart with the new
  binary. Idempotent; no sudo. First run bootstraps the whole setup.
- `dev` — detect if the service is loaded, `bootout` it to free the ports, run
  `go run cmd/server/main.go --enable-tracing --log-level debug` in the foreground
  against `~/.vibecare/vibecare.db`. A `trap … EXIT` restores the service on Ctrl+C,
  only if it was loaded before.
- `service-status` — show whether the agent is loaded, which binary the plist points
  to (local vs prod), the running PID, and whether the ports are busy.
- `service-stop` / `service-start` — manual `bootout` / `bootstrap`.
- `service-restore-prod` — rewrite the plist binary path back to
  `/usr/local/bin/vibecare-server` and reload.

## Constraints

- Use `launchctl bootout` / `bootstrap` / `kickstart` via `gui/$(id -u)/io.vibecare.server`;
  never `kill` (KeepAlive revives it).
- Edit only the installed plist (`~/Library/LaunchAgents/io.vibecare.server.plist`).
  The repo template `scripts/io.vibecare.server.plist` stays `/usr/local/bin` — the PKG
  / production path is untouched. Plists need absolute paths (expand `$HOME`, not `~`).
- All recipes are idempotent and safe when the service is absent (fresh machine).

## Out of scope

Separate dev database, PKG/postinstall changes, macOS-client changes.
