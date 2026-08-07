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

### VibeCare wiring (option D — both interrupt + backend)

Fired from `VibeCheckViewModel` on a confirmed event:

- **(a) Action dispatch** — call the existing `ActionService.ExecuteAction`
  with a user-chosen action ID per behavior (reuses the action inventory:
  notification, play_sound, later an eye-exercise video). **No new backend.**
- **(b) Analytics logging** — record each event so stats persist across
  sessions. Requires a **new minimal backend surface** (see below). Client-side
  session counts work before this lands, so analytics is the final phase.

### Backend surface (Phase 3 only)

Following mono-repo proto conventions (`just proto-gen` regenerates both sides):

- **proto** (`proto/vibecare.proto`): new `DetectionService` with
  `RecordDetection(RecordDetectionRequest) returns (Empty)` and
  `GetDetectionStats(GetDetectionStatsRequest) returns (GetDetectionStatsResponse)`.
  Messages carry behavior type, timestamp, and (for stats) day/hour buckets.
- **migration** (Goose): `detection_events` table (id, behavior, occurred_at,
  device_id/profile_id as applicable).
- **backend** (`backend/internal/api/`): service implementation + repository.
- **Swift** (`Services/DetectionService.swift`): gRPC wrapper used by the view
  model; a simple stats view renders `GetDetectionStats`.

## Data flow

```
Webcam frame
  → CameraSession (downscale, background queue)
  → BFRBDetector (Vision requests → landmarks → region geometry → DetectionResult)
  → DetectionPolicy (smoothing, dwell, cooldown → BFRBEvent)
  → VibeCheckViewModel
      ├─ local interrupt (sound + overlay)         [instant, offline]
      ├─ ActionService.ExecuteAction(actionID)     [vibecare action dispatch]
      └─ DetectionService.RecordDetection(event)   [persistent analytics, Phase 3]
```

## Error handling

- **Camera permission denied / no device** — the screen shows an explanatory
  state with a button to open System Settings; detection simply doesn't start.
- **Vision request failure on a frame** — logged and skipped; the loop
  continues with the next frame (never crashes the session).
- **Backend unreachable** — action dispatch and analytics calls fail
  gracefully; the local interrupt and session counts are unaffected (offline
  still works). Failed analytics events are dropped in v1 (no local queue).

## Testing

- **Go**: table tests for `RecordDetection` / `GetDetectionStats` and the
  migration.
- **Swift**: unit tests for `BFRBDetector` region geometry and
  `DetectionPolicy` debounce/cooldown using fixture landmark data (no camera
  required). `CameraSession` and the live overlay are verified manually via the
  running screen.

## Phased build (each phase is visibly runnable)

1. **Camera + live overlay** — webcam preview with hand skeleton, face box, and
   detection zones drawn. Proves Vision + camera pipeline. Client-only.
2. **Detection + interrupt** — behaviors fire the local sound/overlay interrupt;
   per-behavior toggles, sensitivity and alert-interval settings, live session
   counter. Client-only.
3. **VibeCare wiring** — `ExecuteAction` dispatch per behavior + backend
   analytics (proto / migration / stats service) + a simple stats view.

Where phases contain independent units, they may be built in parallel (e.g.
`BFRBDetector` geometry + `DetectionPolicy` can be developed and unit-tested
alongside `CameraSession`; the Phase 3 backend proto/migration can proceed in
parallel with client polish).

## Out of scope (v1)

- **skin-picking** and **beard-pulling** (harder discrimination; later phase).
- Curated eye/neck/breathing exercise-video interrupts (future action type).
- Cross-platform (Windows/Linux/iOS) — macOS + Apple Vision only for v1.
- Local persistence / offline analytics queue.
- Core ML MediaPipe-hands upgrade (reserve, only if Vision precision fails).

## Decisions locked

- Native macOS client, Apple Vision framework, Neural Engine path.
- Geometric hair-pull zone (no hair segmentation).
- Option D wiring: instant local interrupt + backend (action dispatch +
  persistent analytics).
- v1 behaviors: nail-biting, nose-picking, hair-pulling.
- Camera entitlement + `NSCameraUsageDescription` added to the macOS target.
