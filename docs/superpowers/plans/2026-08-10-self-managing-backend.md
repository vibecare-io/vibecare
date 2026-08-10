# Self-Managing Bundled Backend + Update-Reload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The macOS app brings up its own `vibecare-server` backend on launch via an `SMAppService` LaunchAgent (fixing the cask-install hang), and surfaces a "backend is older than the app — restart to apply" control (with auto-reload) so a `brew upgrade` reloads the daemon.

**Architecture:** Backend gains a `/version` endpoint. CI embeds the signed server + a LaunchAgent plist inside `VibeCare.app`, signed as one bundle. A Swift `BackendManager` registers the agent (`SMAppService`), health-gates startup on `/status`, reads `/version`, compares to the app's own version for staleness, and can restart the agent. The cask installs the app only and kicks the service on upgrade.

**Tech Stack:** Go (net/http), GitHub Actions + codesign, SwiftUI + ServiceManagement (`SMAppService`), Homebrew cask. Backend tests `just test`; client tests xcodebuild; app build `just swift-build`.

## Global Constraints

- Do **not** edit `VCStubs/` or `backend/pkg/proto/` (generated). No proto changes.
- Backend is **not** root; binds `localhost:50051`/`:8080`, DB `~/.vibecare`. Use a **user** `SMAppService.agent` (no admin prompt, no `SMJobBless`).
- Keep the OS-agnostic contract per the spec's cross-platform note: `BackendManager` owns health/`/version`/staleness/UI; a `BackendSupervisor` protocol wraps the macOS `SMAppService` piece so Linux (systemd user) / Windows conformers can be added later. Server flags `--port/--web-port/--db`, and the `/version`+`/status` contract, stay identical across platforms.
- App is `LSUIElement` (agent/menu-bar), not sandboxed; macOS 15+ (SMAppService available).
- LaunchAgent label MUST be `io.vibecare.server` (matches the old plist + the cask kickstart). Server args `--port 50051 --web-port 8080`.
- The app's own version = `Bundle.main.infoDictionary["CFBundleShortVersionString"]`; the release sets it (and `main.version`) to the release version string.
- ⚠️ Case-insensitive FS: client sources on disk lowercase `.../vibecare/…`, git-tracked capital `.../VibeCare/VibeCare/…`. `git add` + verify `git status`.
- Tests: Go `just test` / `go test ./...`; swift-testing whole target (`xcodebuild test … -only-testing:vibecareTests`); `just swift-build`.
- Paths: backend relative to repo root; client relative to `clients/macos-swift/VibeCare/`.

---

## Phase A — self-starting bundled backend (fixes the hang)

### Task A1: Backend `/version` endpoint (TDD)

**Files:**
- Modify: `backend/cmd/server/main.go` (add `var version`, pass to web server)
- Modify: `backend/internal/web/server.go` (`NewServer` gains `version string`; register `/version`)
- Modify: `backend/cmd/server/main.go:193` call site
- Test: `backend/internal/web/version_test.go`

**Interfaces:**
- `NewServer(port int, db *storage.DB, sched *scheduler.Scheduler, mcpServer *mcp.Server, iconLoader IconDataGetter, tracer trace.Tracer, logger *zap.Logger, version string) *Server` — new trailing `version` param.
- `GET /version` → `200`, `Content-Type: application/json`, body `{"version":"<version>"}`.

- [ ] **Step 1: Write the failing test**

Create `backend/internal/web/version_test.go`:

```go
package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"go.uber.org/zap"
)

func TestVersionEndpoint(t *testing.T) {
	// NewServer builds the mux; hit /version through the server's handler.
	srv := NewServer(0, nil, nil, nil, nil, nil, zap.NewNop(), "v9.9.9")
	req := httptest.NewRequest(http.MethodGet, "/version", nil)
	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	var body struct{ Version string `json:"version"` }
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body.Version != "v9.9.9" {
		t.Errorf("version = %q, want v9.9.9", body.Version)
	}
}
```

> This assumes a `Server.Handler() http.Handler` accessor exposing the mux for testing. If `Server` has no such accessor, add one: store the `mux` on `Server` in `NewServer` and add `func (s *Server) Handler() http.Handler { return s.mux }`. The `/version` handler must not require db/sched/mcp (pass `nil` in the test) — register it as a plain handler independent of `NewHandler`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && go test ./internal/web/ -run TestVersionEndpoint`
Expected: FAIL — `/version` returns 404 / `NewServer` arity mismatch / no `Handler()`.

- [ ] **Step 3: Implement**

In `server.go`: add `version string` as the last `NewServer` param; store the `mux` on `Server` (add a `mux *http.ServeMux` field, assign it, and `func (s *Server) Handler() http.Handler { return s.mux }`); register the version route (no middleware needed, but wrapping with `applyMiddleware` is fine):

```go
	versionHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"version": version})
	}
	mux.Handle("/version", applyMiddleware(versionHandler, "version"))
```
(add `"encoding/json"` import.)

In `main.go`: add package-level `var version = "dev"` (overridden by `-ldflags "-X main.version=…"`), log it at startup, and pass `version` as the new last arg at `web.NewServer(...)` (line ~193).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && go test ./internal/web/ -run TestVersionEndpoint -v`
Expected: PASS.

- [ ] **Step 5: Full backend test + build**

Run: `just test` (or `go test ./...`) and `just build`. Expected: green.

- [ ] **Step 6: Commit**

```bash
git add backend/cmd/server/main.go backend/internal/web/server.go backend/internal/web/version_test.go
git commit -m "feat(backend): /version endpoint reporting the build version"
```

---

### Task A2: Embed signed server + LaunchAgent plist into the app bundle (CI)

**Files:**
- Create: `.github/scripts/io.vibecare.server.agent.plist` (SMAppService LaunchAgent template) — or generate inline
- Modify: `.github/workflows/release.yml` (`build-macos-client`: `needs: build-backend`, download server, embed + plist, sign once; `create-release`: tarball app-only)

**Interfaces:** Produces a `VibeCare.app` containing `Contents/Resources/vibecare-server` and `Contents/Library/LaunchAgents/io.vibecare.server.plist`, signed as one bundle. The tarball ships only `VibeCare.app`.

- [ ] **Step 1: Add the LaunchAgent plist**

Create `.github/scripts/io.vibecare.server.plist` (SMAppService agent format):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.vibecare.server</string>
    <key>BundleProgram</key>
    <string>Contents/Resources/vibecare-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/Resources/vibecare-server</string>
        <string>--port</string><string>50051</string>
        <string>--web-port</string><string>8080</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

> Verify against Apple's current `SMAppService` LaunchAgent rules: `BundleProgram` is the executable path relative to the app bundle; `ProgramArguments[0]` should be that same path (args follow). If the launchd job fails to find the program, this is the thing to adjust (documented in the report). Logs go to `~/.vibecare/logs/` — the server creates that dir; if not, add `StandardOutPath`/`StandardErrorPath` with an absolute path resolved at runtime (server already logs to `~/.vibecare/logs/`).

- [ ] **Step 2: Wire embedding + single signing into `build-macos-client`**

In `release.yml` `build-macos-client`: add `needs: build-backend`; after "Create app bundle" and **before** "Sign app bundle", add steps to download the backend artifact and embed it + the plist:

```yaml
      - name: Download backend artifact
        uses: actions/download-artifact@v4
        with:
          name: backend-binary
          path: .
      - name: Embed server + LaunchAgent into app bundle
        run: |
          tar -xvf backend-binary.tar
          mkdir -p VibeCare.app/Contents/Resources VibeCare.app/Contents/Library/LaunchAgents
          cp vibecare-server VibeCare.app/Contents/Resources/vibecare-server
          chmod +x VibeCare.app/Contents/Resources/vibecare-server
          cp .github/scripts/io.vibecare.server.plist \
             VibeCare.app/Contents/Library/LaunchAgents/io.vibecare.server.plist
```

`sign-app-bundle` already uses `codesign --deep`, so the nested `vibecare-server` gets signed by the same identity when the bundle is signed. Keep the existing sign step after this. (`build-backend` already signs the server too; re-signing under `--deep` with the same identity is fine.)

- [ ] **Step 3: `create-release` tarball becomes app-only**

In `create-release`, the app already contains the server. Change the "Create tarball" step to package just the app (the server is inside):

```yaml
          tar -czf ../build/vibecare-${{ steps.version.outputs.version }}-macos.tar.gz VibeCare.app
```
(Remove the separate top-level `vibecare-server` from the tarball. Keep the `.sha256` line.) The backend-binary download/extract steps in `create-release` that placed `dist/vibecare-server` are no longer needed for the tarball, but leaving them is harmless; simplest is to keep `dist/VibeCare.app` handling and tarball only the app.

- [ ] **Step 4: Validate the workflow YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"`
Expected: `YAML OK`. (Signing/embedding correctness is verified by a real release build + manual run — see Phase C.)

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/io.vibecare.server.plist .github/workflows/release.yml
git commit -m "ci(release): embed signed vibecare-server + LaunchAgent into VibeCare.app"
```

---

### Task A3: `BackendManager` + `BackendSupervisor` (SMAppService), staleness logic (TDD)

**Files:**
- Create: `vibecare/Services/Backend/BackendSupervisor.swift` (protocol + `SMAppServiceSupervisor`)
- Create: `vibecare/Services/Backend/BackendManager.swift`
- Test: `vibecareTests/BackendManagerTests.swift`

**Interfaces:**
- `protocol BackendSupervisor { func ensureRegistered() throws; func restart() throws; func isRegistered() -> Bool }`
- `struct SMAppServiceSupervisor: BackendSupervisor` — wraps `SMAppService.agent(plistName: "io.vibecare.server.plist")` (`register`/`unregister`+`register`/`status`).
- `@MainActor final class BackendManager: ObservableObject` with `static let shared`, `enum State { case starting, ready, failed(String) }`, `@Published var state`, `@Published var backendVersion: String?`, `@Published var backendStale: Bool`, `func ensureRunning() async`, `func restart() async`, and a **pure static** `static func isStale(appVersion: String, backendVersion: String?) -> Bool`.
- `init(supervisor: BackendSupervisor = SMAppServiceSupervisor(), appVersion: String = Bundle.main.appVersion, statusURL:…, versionURL:…)` — injectable for tests.

- [ ] **Step 1: Write the failing tests (pure staleness logic)**

Create `vibecareTests/BackendManagerTests.swift`:

```swift
import Testing
@testable import vibecare

@Test func staleWhenBackendOlderOrDifferent() {
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.26") == false)
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.25") == true)
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.26-dirty") == true)
}

@Test func notStaleWhenBackendVersionUnknown() {
    // Unknown backend version (not yet probed / offline) is not "stale" — it's just unknown.
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: nil) == false)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL — `BackendManager` undefined.

- [ ] **Step 3: Implement the supervisor + manager**

Create `BackendSupervisor.swift`:

```swift
import Foundation
import ServiceManagement

protocol BackendSupervisor {
    func ensureRegistered() throws
    func restart() throws
    func isRegistered() -> Bool
}

/// macOS conformer: a bundled user LaunchAgent managed via SMAppService.
/// (Linux/Windows conformers to follow — see the design's cross-platform note.)
struct SMAppServiceSupervisor: BackendSupervisor {
    private var agent: SMAppService { SMAppService.agent(plistName: "io.vibecare.server.plist") }
    func isRegistered() -> Bool { agent.status == .enabled }
    func ensureRegistered() throws { if agent.status != .enabled { try agent.register() } }
    func restart() throws { try? agent.unregister(); try agent.register() }
}
```

Create `BackendManager.swift`:

```swift
import Foundation
import SwiftUI

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

@MainActor
final class BackendManager: ObservableObject {
    static let shared = BackendManager()

    enum State: Equatable { case starting, ready, failed(String) }
    @Published var state: State = .starting
    @Published var backendVersion: String?
    @Published var backendStale = false

    private let supervisor: BackendSupervisor
    private let appVersion: String
    private let statusURL: URL
    private let versionURL: URL

    init(supervisor: BackendSupervisor = SMAppServiceSupervisor(),
         appVersion: String = Bundle.main.appVersion,
         statusURL: URL = URL(string: "http://localhost:8080/status")!,
         versionURL: URL = URL(string: "http://localhost:8080/version")!) {
        self.supervisor = supervisor
        self.appVersion = appVersion
        self.statusURL = statusURL
        self.versionURL = versionURL
    }

    /// Pure, testable: backend is stale iff it reports a version that differs
    /// from the app's own. Unknown (nil) backend version is NOT stale.
    static func isStale(appVersion: String, backendVersion: String?) -> Bool {
        guard let b = backendVersion else { return false }
        return b != appVersion
    }

    func ensureRunning() async {
        state = .starting
        do { try supervisor.ensureRegistered() }
        catch { /* fall through — maybe already running via `just run` */ }
        if await waitForHealthy(timeout: 15) {
            backendVersion = await probeVersion()
            backendStale = Self.isStale(appVersion: appVersion, backendVersion: backendVersion)
            state = .ready
        } else {
            state = .failed("The VibeCare backend didn't start. Check ~/.vibecare/logs/server.log.")
        }
    }

    func restart() async {
        state = .starting
        try? supervisor.restart()
        if await waitForHealthy(timeout: 15) {
            backendVersion = await probeVersion()
            backendStale = Self.isStale(appVersion: appVersion, backendVersion: backendVersion)
            state = .ready
        } else {
            state = .failed("Backend failed to restart.")
        }
    }

    private func waitForHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await probeHealthy() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }
    private func probeHealthy() async -> Bool {
        var req = URLRequest(url: statusURL); req.timeoutInterval = 2
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse { return http.statusCode == 200 }
        return false
    }
    private func probeVersion() async -> String? {
        var req = URLRequest(url: versionURL); req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONDecoder().decode([String:String].self, from: data) else { return nil }
        return obj["version"]
    }
}
```

- [ ] **Step 4: Run tests → GREEN**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **` (the 2 staleness tests pass; existing tests unaffected).

- [ ] **Step 5: Build + commit**

Run: `just swift-build`. Then:
```bash
git add clients/macos-swift/VibeCare/VibeCare/Services/Backend/BackendSupervisor.swift \
        clients/macos-swift/VibeCare/VibeCare/Services/Backend/BackendManager.swift \
        clients/macos-swift/VibeCare/vibecareTests/BackendManagerTests.swift
git status
git commit -m "feat(client): BackendManager + SMAppService supervisor (health-gate, version, staleness)"
```

---

### Task A4: Startup wiring + launching/error UI

**Files:**
- Modify: `vibecare/App.swift` (root startup Task)
- Modify: the root content view (e.g. `vibecare/Views/ContentView.swift` — the view rendered at startup) to gate on `BackendManager.state`

**Interfaces:** Consumes `BackendManager.shared.ensureRunning()` / `.state`.

- [ ] **Step 1: Ensure the backend before loading data**

In `App.swift`'s startup `.onAppear { Task { … } }`, call `await BackendManager.shared.ensureRunning()` **before** `await appState.loadInitialData()`.

- [ ] **Step 2: Gate the UI on backend state**

In the root view, observe `@StateObject private var backend = BackendManager.shared` and switch on `backend.state`:
- `.starting` → a centered "Starting VibeCare…" `ProgressView`.
- `.failed(let msg)` → an error view with `msg` + a **Retry** button (`Task { await backend.ensureRunning() }`) + a hint to open `~/.vibecare/logs/server.log`.
- `.ready` → the existing dashboard/content.

(Read the current root view first and follow its structure; do not change unrelated layout.)

- [ ] **Step 3: Build**

Run: `just swift-build`. Expected: succeeds.

- [ ] **Step 4: Run the full test target (no regressions)**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/App.swift <root-view-path>
git commit -m "feat(client): gate startup on backend readiness (starting/error UI)"
```

---

### Task A5: Cask → app-only + tap update

**Files:**
- Modify (tap repo `vibecare-io/homebrew-apps`): `Casks/vibecare.rb`
- Modify: `.github/workflows/release.yml` `update-homebrew-tap` job's cask template (PR #21 branch may still be open — coordinate; if merged, edit `main`)

**Interfaces:** cask installs `app "VibeCare.app"` only (server embedded).

- [ ] **Step 1: Drop the separate binary stanza**

In the cask (both the live tap `Casks/vibecare.rb` and the workflow's generated template), remove `binary "vibecare-server"` (the server now lives inside the app and is launched by the LaunchAgent). Keep the quarantine-clear postflight and the `.pkg`-migration caveats.

- [ ] **Step 2: Verify (once a build exists)**

Deferred to Phase C after a real release: `brew audit --cask --strict` + `brew fetch`. For now, just make the edit consistent in both places and commit the workflow change.

- [ ] **Step 3: Commit (workflow side)**

```bash
git add .github/workflows/release.yml
git commit -m "ci(cask): install app only (server embedded in bundle)"
```
(Tap-repo edit is pushed directly to `vibecare-io/homebrew-apps` during Phase C when the release exists.)

---

## Phase B — update-available / restart-backend + auto-reload

### Task B1: "Restart backend" banner + button

**Files:**
- Modify: root/content view (add a banner) or the dashboard toolbar
- Consumes: `BackendManager.shared.backendStale`, `.restart()`

- [ ] **Step 1:** When `backend.backendStale` is true, render a dismissible banner: **"A new version is installed — Restart backend to apply"** with a **Restart** button → `Task { await backend.restart() }`. While restarting, show progress; on success `backendStale` clears (versions match).
- [ ] **Step 2:** Build (`just swift-build`) + full test target green.
- [ ] **Step 3:** Commit `feat(client): backend-stale banner with Restart action`.

### Task B2: Auto-reload setting

**Files:**
- Modify: `BackendManager` (read a `UserDefaults` flag `vibecheck… → "backend.autoReload"`, default true) and a Settings toggle in the app's Settings view.

- [ ] **Step 1:** In `ensureRunning()`, after computing `backendStale`, if the persisted `autoReloadBackend` flag is true and `backendStale`, call `await restart()` automatically (so an upgraded app silently reloads the daemon). Expose the flag via a simple `AppStorage`/UserDefaults-backed toggle in Settings ("Automatically restart backend after an update").
- [ ] **Step 2:** Add a focused test if the auto-decision is extracted as a pure function (`shouldAutoRestart(stale:enabled:) -> Bool`); else build + manual.
- [ ] **Step 3:** Build + tests green. Commit `feat(client): auto-reload backend after update (setting)`.

### Task B3: Cask `postflight` kickstart

**Files:** tap `Casks/vibecare.rb` + workflow cask template.

- [ ] **Step 1:** Add to the cask:
```ruby
  postflight do
    system_command "/bin/launchctl",
      args: ["kickstart", "-k", "gui/#{Process.uid}/io.vibecare.server"], sudo: false
  end
```
(alongside the existing quarantine-clear postflight — combine into one `postflight do … end`). This restarts the daemon to the new binary on `brew upgrade`.
- [ ] **Step 2:** `brew audit --cask --strict` once a build exists (Phase C). Commit the workflow template change; push the tap edit in Phase C.

---

## Phase C — verification + handoff

- [ ] **Step 1:** Backend `just test` + `just build` green; client full test target + `just swift-build` green; `release.yml` YAML valid.
- [ ] **Step 2:** Open a PR for the repo changes (backend + CI + client) → user merges → cut a release (`just release <next-version> main`) so a **signed bundle with the embedded server** exists.
- [ ] **Step 3:** Update the tap cask (app-only + postflight) with the new tarball checksum; `brew audit --strict` + `brew fetch`.
- [ ] **Step 4 (manual, user):** fresh `brew install --cask vibecare-io/apps/vibecare` → open app → **backend auto-starts, profiles load (no hang)**; app in Login Items. Quit app → backend keeps running (LaunchAgent); a due schedule still fires a reminder. Then `brew upgrade` to a newer build → cask kicks the service; open app → **no stale banner** (or, with auto-reload off, the banner appears and **Restart** applies it).
- [ ] **Step 5:** Final scope check — only feature files committed; unrelated pre-existing working-tree changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `docs/ideas.org`) not staged.

## Notes / risks

- **Verification is integration-heavy:** SMAppService registration, the embedded-binary signing, and the launchd job only exercise correctly in a **real signed release build** on a Mac — locally we cover the Go `/version` test, the Swift staleness unit tests, and both builds; the daemon lifecycle is proven by the Phase C manual run.
- **SMAppService plist format** (BundleProgram + arguments) is the most likely thing to need a tweak; the plist is isolated in `.github/scripts/io.vibecare.server.plist` for easy iteration.
- **Cross-platform:** `BackendSupervisor` isolates the macOS-only `SMAppService` code so Linux (systemd user) / Windows conformers slot in later without touching `BackendManager` (see the design doc + the `cross-platform-backend-supervisor` memory).
