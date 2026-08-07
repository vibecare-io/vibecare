# VibeCheck — Native BFRB Detection for VibeCare

**Date:** 2026-08-06
**Status:** Approved design, pre-implementation
**Branch:** `feat/plugin-system` (new work may branch from here)

## Summary

VibeCheck is a live, webcam-based behavioral detector built **into the existing
macOS SwiftUI client** as a new sidebar screen. It detects unconscious
body-focused repetitive behaviors (BFRBs) — for v1: **nail-biting,
nose-picking, and hair-pulling** — using Apple's **Vision** framework on the
Neural Engine, fires an **instant local interrupt**, and **wires events into
vibecare** for action-dispatch and persistent analytics.

It is a faster, more efficient native reimagining of the reference browser app
(`thapakazi/projects/vibecheck`, React + MediaPipe). The reference runs
MediaPipe hand/face landmarkers + hair segmentation in a browser; VibeCheck
replaces all of that with native, ANE-accelerated Vision requests.

## Guiding principle

**BFRB detection is a proximity + region problem, not a dense-mesh problem.**
We need only (a) the 5 fingertips from Vision's 21-point hand pose and (b) a
face region. Behaviors are detected by fingertip-to-region geometry. No
MediaPipe, no 468-point face mesh, and **no hair-segmentation model** — the
"hair-pull zone" is derived geometrically by extending the face bounding box
above the forehead and to the temples.

## Why Apple Vision (research conclusion)

Compared against native MediaPipe C++, Core ML converted models, and MPSGraph:

- **Apple Vision** (`DetectHumanHandPoseRequest` + face detection) — runs on the
  Neural Engine (most power-efficient), zero dependencies, no licensing
  friction, fingertip + face precision sufficient for proximity. **Chosen.**
- **Native MediaPipe on macOS** — its Metal/GPU desktop build is broken
  (upstream issue #5656), so it runs CPU-only on Mac — the opposite of the
  efficiency goal. Rejected.
- **Core ML MediaPipe-hands** — held in reserve; adopt *only if* Vision's
  fingertips prove too jittery after filtering.

macOS gotchas: use the modern Swift `DetectHumanHandPoseRequest` (macOS 15+);
`DetectHumanBodyPose3D` is body-only (no fingertips) — not applicable; there is
no new hand-pose model in macOS 26 despite a WWDC25 naming mix-up.

## Architecture

### Client detection core (new units)

Located under `Services/Detection/` and `Views/VibeCheck/`. Each unit has one
purpose, a well-defined interface, and is testable in isolation.

- **`CameraSession`** — wraps `AVCaptureSession` + `AVCaptureVideoDataOutput`.
  Delivers frames on a dedicated background serial queue (`.userInitiated`),
  downscaled to ~640px width, with `alwaysDiscardsLateVideoFrames = true`.
  - Input: camera device. Output: `CVPixelBuffer` stream + preview layer.
  - Depends on: AVFoundation.

- **`BFRBDetector`** — runs Vision requests per (throttled) frame at ~12 FPS.
  Extracts 5 fingertips + face landmarks/box, computes region geometry:
  - **nail-biting**: fingertip near mouth landmarks
  - **nose-picking**: fingertip near nose landmarks
  - **hair-pulling**: fingertip inside the extended forehead/temple zone
  - Output: `DetectionResult { behavior, confidence, fingertipPoint, timestamp }`.
  - **Pure function of landmarks → result.** No camera dependency. Unit-tested
    with fixture landmark sets.

- **`DetectionPolicy`** — converts raw per-frame hits into confirmed *events*.
  Applies: sensitivity threshold, **dwell time** (fingertip must remain in the
  region ≥ N ms), and **alert interval / cooldown** (no spamming).
  - Output: debounced `BFRBEvent`. Pure/testable with synthetic hit sequences.
  - Landmark coordinates are smoothed (moving-average / One-Euro) before policy
    evaluation to reduce fingertip jitter.

- **`VibeCheckViewModel`** (`@MainActor`) — owns session lifecycle, publishes
  live UI state (overlay landmarks, active behavior, per-session counts), and
  routes confirmed events to the interrupt and the backend wiring.

### UI

New **VibeCheck** entry in `SidebarItem` (`Views/Dashboard/Sidebar.swift`) with
a distinct SF Symbol (e.g. `eye.trianglebadge.exclamationmark`) and accent
color, plus a switch arm in `Dashboard`. The screen contains:

- Mirrored live camera preview with a drawn **overlay**: hand skeleton, face
  box, and the active detection zones — so detection is visible while building.
- Per-behavior toggles (nail-biting / nose-picking / hair-pulling).
- Sensitivity slider, alert-interval slider, blur-mode and overlay toggles
  (mirroring the reference's privacy options).
- A live per-session counter.

### The interrupt (local, instant)

On a confirmed `BFRBEvent`: play a sound + flash a translucent overlay/toast,
entirely client-side. Works offline, sub-frame latency. Sound/visual
configurable.

### VibeCare wiring (option D — both interrupt + plugin)

Fired from `VibeCheckViewModel` on a confirmed event:

- **(a) Local action / interrupt** — behaviors trigger a client-side response
  (sound + overlay; later a vibecare notification via `NotificationManager`).
  **Correction:** there is *no* `ActionService.ExecuteAction` RPC — action
  execution in this codebase is client-side, dispatched by type in
  `EventService` (`NotificationManager`, `LinkHandler`, etc.). So the interrupt
  path is entirely native/local, not a backend call.
- **(b) Analytics via a plugin** — record each event so stats persist across
  sessions. This is delegated to a **`plugin-vibecheck` plugin** (see below),
  reached through the *existing* `PluginHostService.InvokePluginAction` RPC.
  Client-side session counts work before the plugin lands, so analytics is the
  final phase.

### `plugin-vibecheck` (Phase 3 — replaces the old "backend surface")

The detection *engine* must be native (camera/Vision/live-preview are
native-shell capabilities a plugin cannot have). But the analytics/stats/history
half is exactly what a plugin does best, so it is delegated to a Go plugin built
on `pluginsdk` — mirroring `backend/cmd/plugin-todos`. This **eliminates all new
backend surface**: no new proto service, no new migration (reuses the
`plugin_data` table via `Host.Store/Query`), and no new Swift service (reuses
`PluginService.invoke`).

- **Location:** new root **`plugins/vibecheck/`** dir (establishing plugins as a
  first-class top-level concept, separate from Core). `plugin-todos` stays at
  `backend/cmd/` for now. Build wiring (justfile + `bin/` output + manifest
  `exec` path) is added for the new location.
- **`plugin-vibecheck` (Go):**
  - `OnAction("record_detection", {behavior, ts})` → `Host.Store("detections",
    uuid, {...})`.
  - `OnRender("main")` → `Host.Query("detections")` → renders counts by behavior
    + a recent-history list as a declarative `List`/`Row` view in the Plugins
    sidebar.
  - `manifest.yaml`: id `com.vibecare.vibecheck`, provides action
    `record_detection`, data collection `detections`.
- **Native client → plugin:** `VibeCheckViewModel` calls
  `PluginService.invoke(pluginId: "com.vibecare.vibecheck",
  action: "record_detection", params: ["behavior": ..., "ts": ...])` on each
  confirmed event. The stats UI appears automatically in the existing Plugins
  screen (no new Swift view required).

## Data flow

```
Webcam frame
  → CameraSession (downscale, background queue)
  → BFRBDetector (Vision requests → landmarks → region geometry → DetectionResult)
  → DetectionPolicy (smoothing, dwell, cooldown → BFRBEvent)
  → VibeCheckViewModel
      ├─ local interrupt (sound + overlay; later NotificationManager)  [instant, offline]
      └─ PluginService.invoke("com.vibecare.vibecheck",
             "record_detection", {behavior, ts})                       [analytics, Phase 3]
                → plugin-vibecheck: Host.Store("detections", …)
                → Plugins sidebar renders stats/history (declarative)
```

## Error handling

- **Camera permission denied / no device** — the screen shows an explanatory
  state with a button to open System Settings; detection simply doesn't start.
- **Vision request failure on a frame** — logged and skipped; the loop
  continues with the next frame (never crashes the session).
- **Plugin/backend unreachable** — the `record_detection` invoke fails
  gracefully (like `PluginService` returning empty on error); the local
  interrupt and session counts are unaffected (offline still works). Failed
  analytics events are dropped in v1 (no local queue).

## Testing

- **Go**: `main_test.go` for `plugin-vibecheck` mirroring
  `backend/cmd/plugin-todos/main_test.go` — drive the plugin subprocess, invoke
  `record_detection`, and assert the rendered stats view + stored data.
- **Swift**: unit tests (Swift Testing / `@Test`) for `BFRBDetector` region
  geometry and `DetectionPolicy` debounce/cooldown using fixture landmark data
  (no camera required), following the protocol-seam DI style of
  `SystemCommandTests.swift`. `CameraSession` and the live overlay are verified
  manually via the running screen.

## Phased build (each phase is visibly runnable)

1. **Camera + live overlay** — webcam preview with hand skeleton, face box, and
   detection zones drawn. Proves Vision + camera pipeline. Client-only.
2. **Detection + interrupt** — behaviors fire the local sound/overlay interrupt;
   per-behavior toggles, sensitivity and alert-interval settings, live session
   counter. Client-only.
3. **Plugin analytics** — `plugin-vibecheck` (root `plugins/vibecheck/`) stores
   detections and renders stats/history in the Plugins sidebar; the native
   client reports each confirmed event via `PluginService.invoke`. Stats UI is
   free from the existing plugin renderer — no new Swift view.

Where phases contain independent units, they may be built in parallel (e.g.
`BFRBDetector` geometry + `DetectionPolicy` can be developed and unit-tested
alongside `CameraSession`; the Phase 3 `plugin-vibecheck` Go work can proceed in
parallel with client polish, since it only depends on the agreed
`record_detection` action name + param shape).

## Out of scope (v1)

- **skin-picking** and **beard-pulling** (harder discrimination; later phase).
- Curated eye/neck/breathing exercise-video interrupts (future action type).
- Cross-platform (Windows/Linux/iOS) — macOS + Apple Vision only for v1.
- Local persistence / offline analytics queue.
- Core ML MediaPipe-hands upgrade (reserve, only if Vision precision fails).

## Decisions locked

- Native macOS client, Apple Vision framework, Neural Engine path.
- Geometric hair-pull zone (no hair segmentation).
- Hybrid architecture: **native detection engine** (Swift client) +
  **`plugin-vibecheck`** (Go) for analytics/stats — no new proto service, no new
  migration, no new Swift service.
- Option D wiring: instant local interrupt (client-side, no `ExecuteAction`
  RPC) + persistent analytics via `PluginService.invoke` →
  `plugin-vibecheck` → `Host.Store`.
- Plugin source lives in a new root **`plugins/vibecheck/`** directory.
- v1 behaviors: nail-biting, nose-picking, hair-pulling.
- Camera usage string via `INFOPLIST_KEY_NSCameraUsageDescription` build
  setting (app uses `GENERATE_INFOPLIST_FILE = YES`, no Info.plist file);
  camera entitlement added to `vibecare.entitlements` only if sandboxed.
- New `.swift` files auto-included via Xcode file-system-synchronized groups —
  no `project.pbxproj` file-registration needed.
