# Handoff — implementing the `vision` and `vibecheck` plugins

**Written:** 2026-08-14, at the end of the session that built the v2 plugin kernel.
**For:** a fresh session with no memory of that work.
**Branch:** `ft/arch_v2` (31 commits ahead of `main`, unmerged, unpushed).

Read this, then the spec. The spec is the binding authority; this document
tells you what is already true, what the last build learned the hard way, and
where the landmines are.

- Spec: [`docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md`](../specs/2026-08-13-plugin-architecture-v2-design.md)
- Prior plan (worked example of the format): [`docs/superpowers/plans/2026-08-13-plugin-architecture-v2-kernel.md`](../plans/2026-08-13-plugin-architecture-v2-kernel.md)

---

## 1. What already exists and works

The v2 kernel is complete and green. Do not rebuild any of this.

| Component | Location | State |
|---|---|---|
| Kernel (12 files, ~5,800 lines) | `backend/kernel/` | done, ~115 tests |
| Plugin SDK | `backend/pkg/vc/` | done, 15 tests |
| Plugin↔core contract | `proto/plugin/v1/plugin.proto` | frozen: 3 RPCs |
| Client↔core contract | `proto/client/v1/client.proto` | frozen: 2 RPCs |
| Reference plugin | `plugins/todo/` | done, own Go module, e2e-tested |
| Swift shell | `vibecare/Models/PluginRoster.swift`, `Services/PluginShellService.swift`, `Views/Plugins/` | done |
| v1 plugin system | — | **deleted** |

A plugin is a subprocess. Core discovers it from `plugins/<id>/manifest.yaml`,
spawns it, supervises it, and reverse-proxies its HTTP at `/p/<id>/`. The
plugin is always a gRPC *client* over `~/.vibecare/core.sock` and never a
server. Clients get a roster and alerts over two streaming RPCs and contain
no plugin-specific code.

**Run it:**

```bash
just run        # backend + plugins from the repo's plugins/ dir
just dev-ui     # same, but plugin UI served from disk with live reload
just swift-run  # the macOS client
```

Core's dashboard is at `<base_url>/_core/status`; get `base_url` from the
`Plugin kernel ready origin=` log line and the token from `~/.vibecare/session`.

---

## 2. What you are building

Spec §16 steps 5 and 6, in that order. **Step 5 first, and it ships before
step 6 exists.**

### Step 5 — `vibecheck` with capture compiled in

One plugin that owns its own camera capture. Landmarks never leave the
process; nothing goes on the bus. `LandmarkFrame` stays an *internal* seam
inside the plugin so step 6 can cut along it later. Its config UI and camera
preview are served from its own HTTP.

This is deliberate: the client-side migration completes without waiting on
the bus contract, and you get a working `vibecheck` before designing
cross-plugin topics.

### Step 6 — extract capture into `vision-macos`

Only when a second consumer exists (spec names `postures`). Two camera opens
means double ANE and double battery, so the split pays for itself only then.
The migration is mechanical *because* of the seam you preserved in step 5.

**Do not do step 6 first.** The spec is explicit about the ordering and the
reason.

---

## 3. The top risk — read this before writing any code

**Spec §17.1: macOS TCC / camera attribution.** A bare binary in `plugins/`
has no `Info.plist` and no `NSCameraUsageDescription`. The permission prompt
and the Control Center "using camera" indicator resolve to whatever spawned
it — which is core, not the plugin.

Spec §16 step 1 says: **spike this before anything else.** A day with a
throwaway cgo binary launched exactly the way the real supervisor launches
it (`exec.Command`, own process group, cwd = plugin dir, three env vars).

Mitigations the spec names, to be confirmed or refuted by the spike:
- ship camera-touching plugins **inside the app bundle** (`Contents/PlugIns/`), signed with the Team ID;
- run core as a **LaunchAgent in the GUI session**, never a system LaunchDaemon.

**This is the one risk that can force a packaging change**, which is why it
comes first. Note that a capture-enabled `vibecheck` (step 5) inherits this
constraint too — it is camera-touching, so it must ship inside the app
bundle. Step 6 moves that constraint to `vision-macos` and frees `vibecheck`
to be an ordinary droppable binary.

The spike was **not** done in the last session. It is still open.

---

## 4. What migrates out of the Swift client

911 lines, still present and still wired into the app today. It works; do not
break it until the plugin replaces it.

```
vibecare/Services/Detection/
  VisionLandmarkExtractor.swift   → vision (step 6) / vibecheck internal (step 5)
  CameraSession.swift             → same
  BFRBDetector.swift              → vibecheck detect/
  DetectionPolicy.swift           → vibecheck detect/
  DetectionPreference.swift       → vibecheck config
  DetectionAlertPreferencesStore.swift → vibecheck config (its own data dir)
  InterruptPlayer.swift           → vibecheck (local interrupt)
vibecare/ViewModels/VibeCheckViewModel.swift → replaced by the plugin
vibecare/Views/VibeCheck/
  CameraPreview.swift             → HTML served by the plugin
  DetectionOverlay.swift          → HTML/canvas served by the plugin
  VibeCheckScreen.swift           → deleted; the roster gives you a tab
  VibeCheckControlsPanel.swift    → plugin HTML
  VibeCheckAlertSettingsView.swift → plugin HTML
vibecare/Models/BFRB.swift        → vibecheck (behavior definitions)
```

Also wired in `Dashboard.swift` (lines ~11, 99, 136, 163, 197) and
`Sidebar.swift` (`case vibecheck`). Those go away — a plugin gets its tab
from the roster automatically, with no client code.

**One dependency already removed:** Task 14 deleted a dead `PluginService`
reporter in `VibeCheckViewModel.swift` that targeted a `com.vibecare.vibecheck`
plugin id which never existed. It was verified dead, not live behaviour.

---

## 5. The contracts you will code against

### Manifest — `plugins/<id>/manifest.yaml`

```yaml
id: vibecheck            # ^[a-z][a-z0-9-]*$ — no dots, no underscores, no caps
name: VibeCheck
icon: eye                # SF Symbol name; the client falls back if invalid
exec: ./vibecheck
subscribes: [sensor.landmarks.v1, activity.afk.v1]
publishes:  [vibecheck.behavior_detected.v1]
ui: webview              # or: none  (headless — runs, but gets no tab)
```

`id` is the routing key, the data-dir name, and the topic namespace prefix.
A malformed manifest is skipped with a warn log; a duplicate id is a hard
startup error.

### SDK — `backend/pkg/vc`

```go
h, err := vc.Connect()   // reads env, registers, reconnects forever, serves /health

h.ID        string       // plugin id
h.DataDir   string       // ~/.vibecare/data/<id>/ — created before spawn
h.Listener  net.Listener // 127.0.0.1:0, already bound; core knows the port
h.Events    <-chan vc.Event  // subscribed bus events; NEVER closed

h.Publish(topic string, payload []byte) error
h.PublishProto(topic string, m proto.Message) error
h.Alert(vc.Alert{Title, Body, Level, Actions}) error
h.OnShutdown(func())                  // flush here; SIGTERM also triggers it
h.SetHealth(func() (status, detail string))  // "ok" | "degraded"
h.Serve(mux *http.ServeMux) error     // nil mux = http.DefaultServeMux
h.Close() error
```

Spawn environment is exactly three variables: `VIBECARE_SOCKET`,
`VIBECARE_PLUGIN_ID`, `VIBECARE_DATA_DIR`. Working directory is the plugin's
own directory.

### HTTP conventions the plugin must follow

| Path | Serves |
|---|---|
| `GET /` | HTML UI |
| `/api/*` | JSON — **the real interface**; the HTML is its first consumer |
| `GET /health` | liveness; SDK provides a default |

Everything else is yours: `/preview.mjpeg`, assets, whatever. Keep `/api/*`
complete and honest — that is what lets a TUI exist later with no core change.

**All URLs in your HTML must be relative.** The plugin is mounted at
`/p/<id>/` and must not know it. **Do not use `localStorage`** — all plugins
share one web origin in v1, and depending on browser storage is what would
make origin isolation expensive to add later.

### Demand refcounting — matters for `vision`, not for step 5

A provider must idle with the camera closed and the LED off when nothing
subscribes. Core refcounts subscribers per topic and delivers a
`_core.demand.v1` event to the *publishing* plugin:

```go
const TopicDemand = "_core.demand.v1"
type DemandPayload struct {
    Topic       string `json:"topic"`
    Subscribers int    `json:"subscribers"`
}
```

It arrives on `h.Events` as JSON, without being declared in `subscribes`. A
provider receives one immediately on connect (so a provider that starts
before any consumer learns the count is 0), then on every change. **Zero
subscribers → close the capture session.** This is a privacy property
enforced by mechanism, which is why it lives in core.

### `proto/topics/v1/landmarks.proto` — does not exist yet

Deliberately deferred: no provider and no consumer existed, and shipping an
untested contract is how it drifts. Spec §10.1 has the full message
definition. Create it when step 6 arrives, or earlier if you want the type
as `vibecheck`'s internal seam.

**The coordinate invariant is the single most common source of silent
breakage** (spec §10.1):

> All coordinates are in **viewer space** — the frame as the user sees
> themselves in a mirrored selfie preview. Origin top-left, `x` right,
> `y` down, normalized `0..1`. Providers apply any mirroring **before**
> publishing. Consumers never mirror.

The macOS front-camera buffer is already mirrored by
`AVCaptureVideoPreviewLayer`, so a macOS provider publishes as-is. This is
stated as an invariant rather than a proto field because a field invites
consumers to branch on it.

An empty `LandmarkFrame` means "nothing detected"; *no message* means the
provider is idle or down. Different things; consumers must treat them
differently.

---

## 6. Hard-won lessons from building the kernel

Reviews found real defects in **eight of fourteen** tasks, several that would
have shipped. These are the patterns that kept biting.

**Concurrency**

- **Never send on a channel outside the lock that guards its close.** `select` with `default` protects against a *full* channel, not a *closed* one — sending on a closed channel panics unconditionally. The kernel sends under the mutex; every send branch has a `default`, so it cannot block. See `bus.go:deliver`.
- **Never signal a pid you have not proven is unreaped.** A reaped pid is recycled, and `kill(-pid, …)` hits a whole process *group*. `supervisor.go:signal` re-reads the pid under the lock, refuses `pid <= 0`, and checks an `exited` channel first. `-race` cannot catch this class — `ESRCH` is silent.
- **Use `Registry.CompareAndSetState` for any state write derived from a state you read earlier.** There are four writers. A slow probe that blindly calls `SetState` will clobber a newer transition.
- **Guard against superseded streams.** A plugin that reconnects has two streams briefly; the old one's teardown must not demote or unsubscribe the new one. Both `rpc.go` and `bus.go` carry identity guards for this.

**Tests**

- **Prove a guard can fail before you trust it.** Two guards in this codebase were decorative and nobody knew: the `FlushInterval` streaming test passed with the value flipped off (Go 1.20+ auto-flushes SSE and unknown-length responses), and `TestStopKillsUnresponsivePlugin` couldn't fail because SIGTERM reaches the process group. Temporarily break the thing, watch the test go red, restore.
- **A test that asserts in-memory round-trip is not a persistence test.** The keystone e2e POSTed and GETed and never touched disk; a no-op flush would have passed it.

**Environment**

- **macOS `sockaddr_un` is 104 bytes.** `t.TempDir()` blows past it, and GitHub's macOS runners have the same long `TMPDIR`. Put test sockets under `os.MkdirTemp("/tmp", …)`. Never depend on `TMPDIR` being set.
- **Do not run `go get` or `go mod tidy` on the `backend` module.** The local toolchain is newer than the declared `go 1.23.0` and will silently bump it. Plugins are their own modules with a `replace` to `../../backend`; that is fine.
- **Commit with an explicit pathspec.** The working tree carries unrelated staged changes (Swift, docs-site, docs) that a bare `git commit` sweeps in. Verify with `git show --stat`. This caught out four separate agents, including me.
- **Do not run `just service-stop`.** It drops the `io.vibecare.server` LaunchAgent registration and leaves the user's backend unsupervised. Use `just dev` (which restores it) or override ports.
- **Two backends must not share one `HOME`.** Both target `~/.vibecare/core.sock`, and the second removes a "stale" socket before binding — correct for a crashed predecessor, but it silently steals the socket from a live one.

**Kernel discipline**

- **D10: no product nouns in `backend/kernel/`.** No `posture`, `nailbiting`, `todo`, `vibecheck`, `detection`, `behavior` — in any `.go` file, comments and test fixtures included. `TestKernelContainsNoProductNouns` fails the build. Kernel test fixtures are named `alpha`/`beta`/`widget`. **This will bite you constantly while building a detection plugin** — none of that vocabulary may leak into core.

---

## 7. Suggested first moves

1. **Do the TCC spike (§3).** A throwaway cgo binary, launched exactly as the supervisor launches it, opening a camera. Answer: whose permission prompt appears, what does Control Center attribute it to, and does shipping inside `Contents/PlugIns/` change it? Report findings; keep no code.
2. **Let the spike's answer settle packaging** before designing `vibecheck`'s build and install path.
3. **Brainstorm `vibecheck` (step 5) as its own spec** — it is architectural: new subsystem, camera lifecycle, its own UI, its own config storage, and a preview surface that is genuinely visual.
4. **Then plan and build it** with `plugins/todo/` as the structural template: own Go module, `manifest.yaml`, `main.go`, `/api/*` plus HTML, tests, and an e2e that drives a real kernel.
5. **Leave the Swift detection code running** until the plugin reaches parity. Delete it in one commit at the end, the way Task 14 removed v1.

## 8. Known gaps in what exists

Carried from the final review, none blocking, all recorded:

- **Alert action buttons are carried on the wire and through the Swift model but not rendered.** The client shows title/body/level only.
- **The WKWebView has never been visually confirmed** — screen capture and Accessibility were permission-blocked in every agent sandbox. Data and transport are proven; rendering is not. One manual launch closes it.
- `vc`'s SIGTERM handler runs the shutdown hook but does not exit, so a plugin with no hook survives to the 5s SIGKILL.
- `runShutdown`'s `sync.Once` can burn if SIGTERM lands between `Connect()` returning and `OnShutdown()` being registered — register the hook immediately after connecting.
- The shutdown drain is a flat 1s sleep rather than drain-or-deadline.
- Adding a plugin requires a core restart; there is no hot-add. Discovery runs once in `Start`.
- `just dev-ui` does not free ports the way `just dev` does.
