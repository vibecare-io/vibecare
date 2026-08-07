# App-Wide VibeCheck Detection + Toolbar/Menu-Bar Toggle — Design & Plan

> Design doc + implementation plan. Date: 2026-08-07. Branch: `feat/plugin-system`.
> Client-only (SwiftUI macOS app under `clients/macos-swift/VibeCare/`).
> Self-contained: written to be executed in a **fresh session** with no prior chat context.

## Problem / Goal

Today VibeCheck detection only runs while the **VibeCheck tab is visible**:
`VibeCheckScreen` starts the camera in `.task { await viewModel.start() }` and stops it
in `.onDisappear { viewModel.stop() }`. Navigating to Schedules/Routines/Actions/etc.
tears the camera down, so detection (and the app-wide nudge notification) stops.

**Goal:** detection runs continuously regardless of the visible tab, controlled by an
explicit on/off toggle exposed in **both** the app's top-right toolbar and the menu-bar
dropdown. The toggle state **persists** and **auto-resumes** on next launch.

## Key facts about the current code (verified)

- `VibeCheckViewModel` (`vibecare/ViewModels/VibeCheckViewModel.swift`) is `@MainActor`,
  owns `camera: CameraSession`, `detector`, `policy`, `sessionCounts`, and the
  detection loop. Its `didOutput(_:)` camera-delegate callback runs on the camera's
  private `frameQueue` **independent of any view**, hops to `@MainActor consume(_:)` →
  `fire(_:)`. So **once the camera session runs, detection + the app-wide VibeNotify
  alert already work from any tab** — no view needs to be on screen.
  - `init(interrupt: InterruptPlaying = InterruptPlayer(), notifier: DetectionNotifying = VibeNotifyDetectionNotifier())`
  - `func start() async` → `camera.receiver = self; let ok = await camera.start(); isRunning = ok; permissionDenied = !ok`
  - `func stop()` → `camera.stop(); isRunning = false`
  - `@Published var isRunning`, `permissionDenied`, `sessionCounts`, `enabledBehaviors`,
    `sensitivity`, `alertInterval`, `flash`, `showOverlay`, `latestFrame`.
- `CameraSession` (`vibecare/Services/Detection/CameraSession.swift`): `let previewLayer:
  AVCaptureVideoPreviewLayer`, `weak var receiver: CameraFrameReceiver?`,
  `func start() async -> Bool`, `func stop()`.
- `Dashboard` (`vibecare/Views/Dashboard/Dashboard.swift`) currently owns the VM:
  `@StateObject private var vibeCheckViewModel = VibeCheckViewModel()`. It renders
  `VibeCheckScreen(viewModel:)` (content) and `VibeCheckControlsPanel(viewModel:)` (detail).
  The always-visible toolbar lives in `contentView.toolbar { ToolbarItemGroup(.primaryAction)
  { toolbarButtons } }`; `toolbarButtons` starts with the notification **bell**
  (`notificationPolicy.toggle()`), then section-specific buttons.
- `MenuBarExtra` already exists in `App.swift` and renders `MenuBarView`
  (defined in `vibecare/Views/PlaceholderViews.swift`). It is a **separate scene** — it
  cannot see `Dashboard`'s `@StateObject`. It already uses `NotificationPolicy.shared`
  and a reusable `MenuBarButton` component (icon/title/action).
- Established app-wide singleton pattern: `AppState.shared`, `NotificationPolicy.shared`
  (`@MainActor` `ObservableObject`s with `static let shared`, consumed as
  `@StateObject private var x = X.shared`). `NotificationPolicy.toggle()` + `.enabled`
  drive both the toolbar bell and the menu-bar row today — the exact pattern to mirror.
- `App.swift` startup: `ContentView().onAppear { Task { await appState.loadInitialData(); ... } }`.
  This Task is where `resumeIfEnabled()` should be called.
- Tests: swift-testing (`import Testing`, `@Test`, `#expect`, `@testable import vibecare`)
  in `vibecareTests/`. **Tests run via xcodebuild, not SwiftPM** (no test target in
  `Package.swift`): `xcodebuild test -project vibecare.xcodeproj -scheme vibecare
  -destination 'platform=macOS' -only-testing:vibecareTests`. `vibecareTests/` is a
  `PBXFileSystemSynchronizedRootGroup`, so new test files are auto-included. App builds via
  `just swift-build` (SwiftPM) — quick sanity — and also under xcodebuild.
- ⚠️ Case-insensitive-FS quirk: git tracks app sources under capital
  `clients/macos-swift/VibeCare/VibeCare/...`; new files may show at lowercase
  `.../vibecare/...`. When committing, `git add` the **capital** path (see prior commits
  `c620870`, `f8f5363`).

## Decisions (confirmed with the user)

- **Persist & auto-resume:** the toggle is saved; if it was on at quit, the camera
  auto-starts on next launch (after `loadInitialData`). If camera permission is denied on
  resume, the flag resolves back to off so we don't loop into a broken state.
- **Toggle in both places:** app top-right toolbar **and** menu-bar dropdown, both driving
  the one shared state.

## Design

### 1. Promote `VibeCheckViewModel` to an app singleton
- Add `static let shared = VibeCheckViewModel()` (init already has all-default args).
- `Dashboard`: replace `@StateObject private var vibeCheckViewModel = VibeCheckViewModel()`
  with `@StateObject private var vibeCheckViewModel = VibeCheckViewModel.shared`.
- Tests keep constructing their own instances via the init — do **not** route tests
  through `.shared`.

### 2. Decouple the camera from the screen
- In `VibeCheckScreen`, **remove** `.task { await viewModel.start() }` and
  `.onDisappear { viewModel.stop() }`. The screen no longer controls the camera.
- Screen becomes a viewer (see §6 for the off-state).

### 3. Explicit toggle + persistence
- New `@Published private(set) var isDetectionEnabled: Bool` on the VM (default from the
  persisted flag).
- New injectable persistence unit **`DetectionPreference`** (the TDD'd piece):
  ```swift
  protocol DetectionPreferenceStoring { var enabled: Bool { get set } }
  struct DetectionPreference: DetectionPreferenceStoring {
      private let defaults: UserDefaults
      private let key = "vibecheck.detection.enabled"
      init(defaults: UserDefaults = .standard) { self.defaults = defaults }
      var enabled: Bool {
          get { defaults.bool(forKey: key) }   // defaults to false when unset
          set { defaults.set(newValue, forKey: key) }
      }
  }
  ```
  Inject into the VM init as `preference: DetectionPreferenceStoring = DetectionPreference()`.
- VM methods:
  ```swift
  func setDetection(_ on: Bool) async {
      if on {
          await start()                 // sets isRunning / permissionDenied
          isDetectionEnabled = isRunning
      } else {
          stop()
          isDetectionEnabled = false
      }
      preference.enabled = isDetectionEnabled   // persist resolved intent
  }
  func toggleDetection() async { await setDetection(!isDetectionEnabled) }
  func resumeIfEnabled() async { if preference.enabled { await setDetection(true) } }
  ```
- `App.swift`: in the existing startup Task (after `await appState.loadInitialData()`),
  add `await VibeCheckViewModel.shared.resumeIfEnabled()`.

### 4. Toolbar toggle (`Dashboard.toolbarButtons`)
Add as the first always-visible button (before the bell, or right after it):
```swift
Button {
    Task { await vibeCheckViewModel.toggleDetection() }
} label: {
    Image(systemName: vibeCheckViewModel.isDetectionEnabled ? "eye.fill" : "eye.slash")
}
.help(vibeCheckViewModel.isDetectionEnabled ? "Stop VibeCheck detection" : "Start VibeCheck detection")
```

### 5. Menu-bar toggle (`MenuBarView` in `PlaceholderViews.swift`)
- Add `@StateObject private var vibeCheck = VibeCheckViewModel.shared` to `MenuBarView`.
- Add a `MenuBarButton` in the action section (near "Pause Notifications"):
  ```swift
  MenuBarButton(
      icon: vibeCheck.isDetectionEnabled ? "video.fill" : "video.slash",
      title: vibeCheck.isDetectionEnabled ? "Detection: On" : "Turn On Detection",
      action: { Task { await vibeCheck.toggleDetection() } }
  )
  ```
- (Optional, nice-to-have) a small detection status dot in the header — keep the existing
  header tied to notifications; only add the row to stay minimal.

### 6. VibeCheck screen off-state (`VibeCheckScreen`)
- When `!viewModel.isDetectionEnabled` (and not permission-denied): show a centered
  prompt — icon (`eye.slash`), "Detection is off", subtitle "Turn it on to start
  monitoring", and a `Button("Start Detection") { Task { await viewModel.setDetection(true) } }`.
- When enabled: existing live preview + `DetectionOverlay` + flash + overlay toggle.
- Keep `permissionView` for `permissionDenied`.
- The `VibeCheckControlsPanel` (detail) is unchanged and stays usable regardless.

## Testing (TDD)

Unit-test the **pure persistence logic** — the piece with real branching that doesn't need
camera hardware. Do **not** fake AVFoundation.

New `vibecareTests/DetectionPreferenceTests.swift` (use an ephemeral
`UserDefaults(suiteName:)` so `.standard` isn't polluted; remove the suite after):
- defaults to `false` when unset.
- `enabled = true` persists and reads back `true`; `= false` reads back `false`.
- a second `DetectionPreference` over the **same** suite sees the persisted value
  (proves it's backed by the store, not in-memory).

Camera start/stop on toggle, `resumeIfEnabled` acting on the flag, and all UI wiring are
verified by `just swift-build` + xcodebuild build + the user's manual run. The existing
`VibeCheckViewModelTests` (spy notifier) must stay green.

## Implementation plan (ordered, for a fresh session)

1. **`DetectionPreference` (TDD).** Write `DetectionPreferenceTests.swift` first (RED via
   xcodebuild), then add `DetectionPreference` + `DetectionPreferenceStoring`
   (new file `vibecare/Services/Detection/DetectionPreference.swift`). GREEN.
2. **VM singleton + toggle/persist/resume.** Add `static let shared`, inject
   `preference:`, add `isDetectionEnabled`, `setDetection`, `toggleDetection`,
   `resumeIfEnabled`. Keep the existing `start()/stop()`. Build.
3. **Decouple screen.** Remove `.task/.onDisappear` from `VibeCheckScreen`; add the
   off-state (§6). Build.
4. **Dashboard.** Point `vibeCheckViewModel` at `.shared`; add the toolbar toggle to
   `toolbarButtons`. Build.
5. **MenuBarView.** Observe `.shared`; add the detection `MenuBarButton`. Build.
6. **App resume.** Call `resumeIfEnabled()` in `App.swift` startup Task. Build.
7. **Verify.** `xcodebuild test ... -only-testing:vibecareTests` → all green
   (new + existing). `just swift-build` green. Hand off to user for the manual run:
   toggle from toolbar and menu bar, navigate to another tab, confirm detection + nudge
   still fire; quit with it on, relaunch, confirm it auto-resumes.
8. **Commit.** Stage only the feature files (capital paths) + this spec; exclude unrelated
   `VCStubs`/`docs-site`/`backlog`/stray-binary changes.

## Non-goals
- No change to detection geometry/sensitivity/policy or the notification look.
- No camera-hardware abstraction/fake (keep `CameraSession` concrete).
- Menu-bar header badge stays tied to notifications; detection gets its own row.
- No new global hotkey (could be a follow-up).
