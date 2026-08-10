# Self-Managing Bundled Backend + Update-Reload — Design & Spec

> Design doc. Date: 2026-08-10. Branch: TBD off `main`.
> Spans: Go backend, macOS Swift client, release CI, Homebrew cask.
> Self-contained for a fresh session.

## Problem / Goal

The Homebrew/tarball install ships `VibeCare.app` + `vibecare-server` but nothing
starts the backend. Opening the app launches the Swift client, which can't reach
the backend (gRPC `:50051` / HTTP `:8080`), so `listProfiles()` returns empty and
the UI hangs on the "Select Profile / No profiles found" dialog (the old `.pkg`
installed a LaunchAgent via `postinstall`; the cask has no such thing).

**Goal:** the app brings up its own backend on launch — the macOS-native
equivalent of a Docker/Tailscale "GUI + daemon". Use Apple's `SMAppService` to
register a **bundled** `vibecare-server` LaunchAgent (no `.pkg`, no admin
password, no root — the backend binds localhost and writes `~/.vibecare`). Then
surface an in-app **"a new version is installed — restart backend to apply"**
control (with an auto option) so a `brew upgrade` that swaps the app files also
gets the running daemon onto the new binary.

## Confirmed decisions (with the user)

- **Model:** `SMAppService` **LaunchAgent** (user-level, always-on: `RunAtLoad` +
  `KeepAlive`) — Tailscale-style always-on daemon, so scheduled reminders fire even
  when the app window/menu-bar is closed. The server is **embedded in the app
  bundle** so the `.app` is self-contained (cask installs only the app).
- **Update-reload UX:** the client compares the running backend's version to its
  own bundled version; when the backend is stale it shows a **"New version
  installed — Restart backend"** banner/button, with a **Settings toggle to
  auto-reload**. A cask `postflight` also kicks the service on `brew upgrade`.

## Key facts (verified)

- **Backend build already embeds the version:** `.github/scripts/build-universal-binary.sh`
  builds with `-ldflags "-X main.version=$VERSION"`. But `backend/cmd/server/main.go`
  has **no `version` var and no `/version` endpoint** — must be added.
- **HTTP server** (`backend/internal/web/server.go`) registers routes on a `mux`
  (e.g. `mux.Handle("/status", …)`). Add `/version` here (or in main). `/status`
  returns 200 when up — usable as readiness. Server flags: `--port 50051
  --web-port 8080 --db <path>` (db empty → default `~/.vibecare/vibecare.db`).
  Server runs `goose.Up` migrations on startup (`backend/internal/storage/db.go`),
  so launching the binary fully initializes the DB.
- **App bundle:** `.github/scripts/create-app-bundle.sh` writes `Info.plist` with
  `CFBundleShortVersionString`/`CFBundleVersion` = release version, and puts the app
  binary at `Contents/MacOS/VibeCare`. It does **not** embed the server. Bundle id
  `io.vibecare.app` (from CI) — note the Xcode project uses
  `io.vibecare.App.vibecare`; the CI-built bundle uses `io.vibecare.app`.
- **App is NOT sandboxed** (`vibecare.entitlements` has no
  `com.apple.security.app-sandbox`), so it may register a `SMAppService.agent` and
  the agent may spawn the server. `SMAppService` is macOS 13+; the app targets
  macOS 15 — available.
- **Client:** `AppState.loadInitialData()` calls `ProfileService.listProfiles()`;
  on connection failure it returns empty → `showProfileSelector = true` (the hang).
  `NetworkConfiguration` defaults: backend `http://localhost:8080`, gRPC
  `grpc://localhost:50051`. The app reads its own version via
  `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
- **Release/cask (current):** `create-release` tarballs `vibecare-server` +
  `VibeCare.app` side by side; cask installs `app "VibeCare.app"` + `binary
  "vibecare-server"` (see `2026-08-08-vibecheck-default-icons` era work / the tap
  `vibecare-io/homebrew-apps`).
- ⚠️ Case-insensitive FS: client sources on disk at lowercase `.../vibecare/…`,
  git-tracked under capital `.../VibeCare/VibeCare/…`. `git add` + verify with
  `git status`.

## Design

### Phase A — self-starting bundled backend (fixes the hang)

**A1. Backend `/version` endpoint.**
- In `backend/cmd/server/main.go` declare `var version = "dev"` (overridden by the
  existing ldflag `-X main.version=…`).
- Register `GET /version` on the web mux returning JSON `{"version": "<version>"}`
  (add in `web.Server` with the version passed in, or a small handler in main
  wired into the mux). Log the version at startup.

**A2. Embed the signed server + LaunchAgent plist into the app bundle (CI).**
- Make `build-macos-client` depend on `build-backend`; download the signed
  `vibecare-server` artifact; copy it to `VibeCare.app/Contents/Resources/vibecare-server`
  **before** `sign-app-bundle`, and add
  `VibeCare.app/Contents/Library/LaunchAgents/io.vibecare.server.plist`. Then sign
  the whole bundle so the nested binary + plist are covered (sign nested code first
  if needed, then the app). `create-release` tarballs the app (server inside); it
  no longer ships a separate top-level `vibecare-server`.
- **LaunchAgent plist** (`SMAppService` format): `Label = io.vibecare.server`,
  `BundleProgram = Contents/Resources/vibecare-server`, arguments `--port 50051
  --web-port 8080`, `RunAtLoad = true`, `KeepAlive` (restart on failure),
  `StandardOut/ErrorPath = ~/.vibecare/logs/server.log`. (Implementer: follow
  Apple's current `SMAppService` LaunchAgent plist rules for `BundleProgram` +
  arguments; verify the launchd job runs the bundled binary.)

**A3. Client `BackendManager` (new `@MainActor` service).**
```
final class BackendManager: ObservableObject {
    static let shared
    enum State { case unknown, starting, ready, failed(String) }
    @Published var state: State
    @Published var backendVersion: String?   // from /version once ready

    // Registers the SMAppService agent if needed, then waits for readiness.
    func ensureRunning() async
    // Health probe: GET http://localhost:8080/status (short timeout) → up?
    // Version probe: GET /version → backendVersion
    // restart(): SMAppService.unregister() then register() (reloads plist+binary)
}
```
- `ensureRunning()`: if `SMAppService.agent(plistName:).status` isn't enabled, call
  `register()`. Poll `/status` until 200 (timeout ~15s, backoff). On success set
  `.ready` and fetch `/version`. On timeout set `.failed(...)`.
- If a backend is **already running** (dev `just run`, or a prior agent), `/status`
  answers immediately → reuse; do not double-register/kill it beyond what
  SMAppService idempotently manages.

**A4. Startup wiring + UI (`App.swift`, root view).**
- In the startup Task, `await BackendManager.shared.ensureRunning()` **before**
  `appState.loadInitialData()`.
- Root view shows a **"Starting VibeCare…"** state while `state == .starting`,
  and a real **error + Retry** when `.failed` (instead of the misleading empty
  profile selector). Only proceed to the normal dashboard when `.ready`.

**A5. Cask (tap `vibecare-io/homebrew-apps`).**
- Cask installs `app "VibeCare.app"` only (drop the separate `binary`, since the
  server is embedded). Keep the quarantine-clear postflight.
- The app itself registers/unregisters the agent (SMAppService); document in
  caveats that quitting removes the login item is a future nicety.

### Phase B — update-available / restart-backend + auto-reload

**B1. Stale detection.** The app's own version = `CFBundleShortVersionString`. When
`.ready`, compare `backendVersion` to the app version. If they differ (running
backend older than the installed app — the post-`brew upgrade` case), set
`@Published var backendStale = true` on `BackendManager`.

**B2. UI.** When `backendStale`, show a banner/toolbar item: **"A new version is
installed — Restart backend to apply"** with a **Restart** button → `await
BackendManager.shared.restart()` (SMAppService unregister→register; then re-probe
`/version`; clear `backendStale` when versions match).

**B3. Auto-reload setting.** A Settings toggle `autoReloadBackend` (UserDefaults,
default on). When on and `backendStale` is detected on launch, call `restart()`
automatically instead of only showing the banner.

**B4. Cask `postflight` reload.** Add to the cask:
```ruby
postflight do
  system_command "/bin/launchctl",
    args: ["kickstart", "-k", "gui/#{Process.uid}/io.vibecare.server"], sudo: false
end
```
so `brew upgrade` restarts the daemon to the new binary immediately (best-effort;
`|| true` semantics — ignore if not loaded). The app-side re-register (B2/B3)
remains the robust path (also handles a changed plist). `KeepAlive` means any
crash/reboot also brings up the new binary.

## Cross-platform (future — Linux / Windows clients)

This spec implements macOS. The **contract** must stay platform-agnostic so future
clients reuse it; only the launcher/supervisor differs per OS. Design
`BackendManager` around a small protocol:

```
protocol BackendSupervisor {           // one conformer per platform
    func ensureRegistered() async throws // install/enable the OS service
    func restart() async throws          // reload to the on-disk binary
    func isRegistered() -> Bool
}
```
`BackendManager` owns the OS-agnostic parts (health probe `/status`, `/version`
fetch, staleness compare, state machine, UI signals); `BackendSupervisor` is the
per-OS piece. The health/version endpoints and the "restart backend to apply an
update" UX are identical everywhere — only how the daemon is supervised changes:

| OS | Supervisor (Docker `restart:` equivalent) | Notes |
|----|-------------------------------------------|-------|
| **macOS** | `SMAppService` user **LaunchAgent** (this spec) | RunAtLoad + KeepAlive; no root |
| **Linux** | **systemd user service** (`systemctl --user enable --now vibecare-server`) with `Restart=on-failure`; user unit installed under `~/.config/systemd/user/` | fall back to XDG autostart + app-spawned child if systemd absent |
| **Windows** | app-managed child process + **Startup**/Task Scheduler registration, or a Windows Service (`sc`/`New-Service`) | service needs admin; prefer per-user Startup + app supervision |

Keep the server flags (`--port/--web-port/--db`), the `/version` + `/status`
contract, and the update-reload semantics identical across platforms so only the
`BackendSupervisor` conformer is written per OS.

## Testing

- **Backend (Go, TDD):** test `GET /version` returns the injected version (set the
  `version` var in the test or assert the default), and that it's valid JSON.
- **Client (swift-testing, pure logic):** `BackendManager`'s version-staleness
  comparison is a pure function — test `isStale(app:backend:)` (equal → false,
  backend older/different → true, nil backend → not stale/unknown). The
  SMAppService registration, subprocess, health-poll, and UI are integration —
  verified by build + manual run.
- **Manual run** (the real proof): fresh `brew install` → open app → backend
  auto-starts, profiles load (no hang). Quit → (Phase A always-on) backend keeps
  running; a scheduled reminder still fires. Simulate an upgrade (bump app version
  / install newer) → banner appears → Restart applies it; toggle auto-reload.

## Non-goals

- No root LaunchDaemon / `SMJobBless` / privileged helper (backend needs no root).
- No external appcast / "newer release on GitHub" check (Sparkle-style) — "update
  available" here means the **running backend is older than the installed app**,
  not that a newer release exists upstream. (Possible follow-up.)
- No Docker/containerization for the shipped app.
- No change to detection/notification features or the notarization decision.
```
