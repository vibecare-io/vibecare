# Plan: Local-Build Backend Workflow

Ref: [design](2026-07-22-local-backend-workflow-design.md)

All work is in `Justfile`, `📦 Build & Run` group, inserted after `run-port`.

1. Add `deploy-local` — build release binary → copy to `~/.local/bin/vibecare-server`
   → repoint installed plist if needed (`sed` + `bootout`/`bootstrap`) else
   `kickstart -k`. Guard: error if plist missing.
2. Add `dev` — capture loaded state via `launchctl print`, `bootout` to free ports,
   `go run` in foreground, `trap restore EXIT` to `bootstrap` back if it was loaded.
3. Add `service-status` — loaded state, plist binary path (local vs prod), PID, port
   50051/8080 usage.
4. Add `service-stop` / `service-start` — manual `bootout` / `bootstrap`.
5. Add `service-restore-prod` — `sed` plist path back to `/usr/local/bin`, reload.

All recipes use `gui/$(id -u)/io.vibecare.server` and `$HOME` (never `~`) in plists.

## Verify

- `just service-status` reports current state (prod build, loaded, ports in use).
- `just deploy-local` builds, installs to `~/.local/bin`, repoints, service runs local build.
- `just dev` frees ports, runs go server, Ctrl+C restores the service.
- `just service-restore-prod` puts the plist back to `/usr/local/bin`.
