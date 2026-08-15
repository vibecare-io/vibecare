# App-Wide VibeCheck Detection + Toolbar/Menu-Bar Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make VibeCheck detection run continuously regardless of the visible tab, controlled by a persisted on/off toggle exposed in both the app toolbar and the menu-bar dropdown, auto-resuming on next launch.

**Architecture:** Promote `VibeCheckViewModel` to an app singleton (`.shared`) so the toolbar (Dashboard scene) and menu bar (separate `MenuBarExtra` scene) drive one shared camera. Decouple the camera lifecycle from `VibeCheckScreen` (which becomes a pure viewer) and gate it on a new `isDetectionEnabled` flag backed by an injectable `DetectionPreference` (UserDefaults). Auto-resume on launch from the persisted flag. Mirrors the existing `NotificationPolicy.shared` singleton pattern already used for the notification bell.

**Tech Stack:** SwiftUI (macOS 15+), swift-testing (`import Testing`), UserDefaults, AVFoundation (existing `CameraSession`, untouched). Tests run via xcodebuild; app builds via `just swift-build` (SwiftPM).

## Global Constraints

- Platform: macOS 15+; SwiftUI client only. No backend/proto changes.
- Swift client has **no local persistence** except UserDefaults — the toggle flag uses UserDefaults, consistent with existing `grpc_url`/`currentProfileId` usage.
- UserDefaults key for the flag: `"vibecheck.detection.enabled"` (verbatim).
- Do **not** edit `VCStubs/` (generated).
- Do **not** fake AVFoundation / abstract `CameraSession` — keep it concrete.
- ⚠️ Case-insensitive-FS quirk: git tracks app sources under **capital** `clients/macos-swift/VibeCare/VibeCare/...`; new files may appear at lowercase `.../vibecare/...`. When committing, `git add` the **capital** path (see prior commits `c620870`, `f8f5363`).
- Tests: swift-testing in `vibecareTests/` (a `PBXFileSystemSynchronizedRootGroup`, so new test files auto-include). Run with:
  `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests`
- Existing `VibeCheckViewModelTests` (spy notifier) must stay green. Tests construct their own VM via `init(...)` — never route tests through `.shared`.
- All paths below are relative to `clients/macos-swift/VibeCare/`.

---

### Task 1: `DetectionPreference` persistence unit (TDD)

**Files:**
- Create: `vibecare/Services/Detection/DetectionPreference.swift`
- Test: `vibecareTests/DetectionPreferenceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol DetectionPreferenceStoring { var enabled: Bool { get set } }`
  - `struct DetectionPreference: DetectionPreferenceStoring` with `init(defaults: UserDefaults = .standard)` and a settable `var enabled: Bool` backed by UserDefaults key `"vibecheck.detection.enabled"`.

- [ ] **Step 1: Write the failing tests**

Create `vibecareTests/DetectionPreferenceTests.swift`:

```swift
import Testing
import Foundation
@testable import vibecare

@Suite struct DetectionPreferenceTests {

    /// Makes an isolated UserDefaults suite so `.standard` is never polluted.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "test.vibecheck.detection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test func defaultsToFalseWhenUnset() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let pref = DetectionPreference(defaults: defaults)

        #expect(pref.enabled == false)
    }

    @Test func persistsTrueThenFalse() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        var pref = DetectionPreference(defaults: defaults)
        pref.enabled = true
        #expect(pref.enabled == true)

        pref.enabled = false
        #expect(pref.enabled == false)
    }

    @Test func secondInstanceOverSameSuiteSeesPersistedValue() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        var writer = DetectionPreference(defaults: defaults)
        writer.enabled = true

        let reader = DetectionPreference(defaults: defaults)
        #expect(reader.enabled == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests/DetectionPreferenceTests`
Expected: FAIL — compile error, `DetectionPreference` / `DetectionPreferenceStoring` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `vibecare/Services/Detection/DetectionPreference.swift`:

```swift
import Foundation

/// Injectable persistence for the app-wide VibeCheck detection on/off flag.
/// Abstracted so `VibeCheckViewModel` can be tested against an in-memory
/// stand-in instead of `.standard` UserDefaults.
protocol DetectionPreferenceStoring {
    var enabled: Bool { get set }
}

/// UserDefaults-backed detection flag. Defaults to `false` when unset
/// (`UserDefaults.bool(forKey:)` returns `false` for a missing key).
struct DetectionPreference: DetectionPreferenceStoring {
    private let defaults: UserDefaults
    private let key = "vibecheck.detection.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests/DetectionPreferenceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Services/Detection/DetectionPreference.swift \
        clients/macos-swift/VibeCare/vibecareTests/DetectionPreferenceTests.swift
git commit -m "feat(vibecheck): DetectionPreference for persisted detection flag"
```

> Note: if `git add` of the capital path fails (file materialized at lowercase), run `git status` and add the path git actually reports. The capital path is preferred; verify with `git status` before committing.

---

### Task 2: VibeCheckViewModel singleton + toggle/persist/resume

**Files:**
- Modify: `vibecare/ViewModels/VibeCheckViewModel.swift`

**Interfaces:**
- Consumes: `DetectionPreferenceStoring`, `DetectionPreference` (Task 1); existing `start()`, `stop()`, `isRunning`, `permissionDenied`.
- Produces (relied on by Tasks 3–6):
  - `static let shared = VibeCheckViewModel()`
  - `@Published private(set) var isDetectionEnabled: Bool`
  - `func setDetection(_ on: Bool) async`
  - `func toggleDetection() async`
  - `func resumeIfEnabled() async`
  - `init` gains a third param: `preference: DetectionPreferenceStoring = DetectionPreference()`.

- [ ] **Step 1: Add the singleton, stored preference, and published flag**

In `vibecare/ViewModels/VibeCheckViewModel.swift`, add the shared instance and a stored preference property. Add near the top of the class body (after the existing `@Published` block, before `private var detector`):

```swift
    /// App-wide instance shared by the Dashboard toolbar and the menu-bar
    /// scene so a single camera session backs both toggles. Tests must NOT
    /// use this — they construct their own VM via `init(...)`.
    static let shared = VibeCheckViewModel()

    /// Reflects the user's explicit intent to run detection. Distinct from
    /// `isRunning` (actual camera state): they can diverge briefly, e.g. when
    /// permission is denied on resume the intent resolves back to `false`.
    @Published private(set) var isDetectionEnabled: Bool

    private var preference: DetectionPreferenceStoring
```

- [ ] **Step 2: Extend the initializer**

Replace the existing initializer:

```swift
    init(
        interrupt: InterruptPlaying = InterruptPlayer(),
        notifier: DetectionNotifying = VibeNotifyDetectionNotifier()
    ) {
        self.interrupt = interrupt
        self.notifier = notifier
    }
```

with:

```swift
    init(
        interrupt: InterruptPlaying = InterruptPlayer(),
        notifier: DetectionNotifying = VibeNotifyDetectionNotifier(),
        preference: DetectionPreferenceStoring = DetectionPreference()
    ) {
        self.interrupt = interrupt
        self.notifier = notifier
        self.preference = preference
        self.isDetectionEnabled = preference.enabled
    }
```

- [ ] **Step 3: Add the toggle / set / resume methods**

Insert these methods immediately after the existing `stop()` method (after its closing brace, before `nonisolated func didOutput`):

```swift
    /// Turns detection on or off and persists the resolved intent. When
    /// turning on, `isDetectionEnabled` follows whether the camera actually
    /// started (`isRunning`) — a denied permission resolves the flag back to
    /// `false` so resume can't loop into a broken state.
    func setDetection(_ on: Bool) async {
        if on {
            await start()
            isDetectionEnabled = isRunning
        } else {
            stop()
            isDetectionEnabled = false
        }
        preference.enabled = isDetectionEnabled
    }

    func toggleDetection() async {
        await setDetection(!isDetectionEnabled)
    }

    /// Called once at app startup: restores detection if it was on at last quit.
    func resumeIfEnabled() async {
        if preference.enabled {
            await setDetection(true)
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 5: Run existing VM tests to confirm they stay green**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests/VibeCheckViewModelTests`
Expected: PASS (existing spy-notifier test unaffected; `init` still callable with two args because `preference` has a default).

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/ViewModels/VibeCheckViewModel.swift
git commit -m "feat(vibecheck): shared VM with persisted detection toggle + resume"
```

---

### Task 3: Decouple the camera from VibeCheckScreen + off-state

**Files:**
- Modify: `vibecare/Views/VibeCheck/VibeCheckScreen.swift`

**Interfaces:**
- Consumes: `viewModel.isDetectionEnabled`, `viewModel.setDetection(_:)`, `viewModel.permissionDenied` (Task 2); existing preview/overlay members.
- Produces: nothing new; screen becomes a viewer that no longer starts/stops the camera.

- [ ] **Step 1: Remove camera lifecycle, gate the live view on `isDetectionEnabled`, add off-state**

Replace the entire `body` (lines 6–25) — remove `.task { await viewModel.start() }` and `.onDisappear { viewModel.stop() }`, and branch on detection state:

```swift
    var body: some View {
        ZStack {
            if viewModel.permissionDenied {
                permissionView
            } else if !viewModel.isDetectionEnabled {
                detectionOffView
            } else {
                CameraPreview(previewLayer: viewModel.camera.previewLayer)
                    .ignoresSafeArea()
                if viewModel.showOverlay {
                    DetectionOverlay(frame: viewModel.latestFrame,
                                      enabledBehaviors: viewModel.enabledBehaviors)
                        .ignoresSafeArea()
                }
                flashOverlay
                overlayToggle
            }
        }
        .navigationTitle("VibeCheck")
    }
```

- [ ] **Step 2: Add the off-state view**

Add this computed property to `VibeCheckScreen` (e.g. immediately after `permissionView`):

```swift
    private var detectionOffView: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 40))
            Text("Detection is off").font(.title3).bold()
            Text("Turn it on to start monitoring")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Start Detection") {
                Task { await viewModel.setDetection(true) }
            }
            .buttonStyle(.borderedProminent)
        }
    }
```

- [ ] **Step 3: Build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Views/VibeCheck/VibeCheckScreen.swift
git commit -m "feat(vibecheck): decouple camera from screen; add detection-off state"
```

---

### Task 4: Dashboard — point at `.shared` + toolbar toggle

**Files:**
- Modify: `vibecare/Views/Dashboard/Dashboard.swift`

**Interfaces:**
- Consumes: `VibeCheckViewModel.shared`, `isDetectionEnabled`, `toggleDetection()` (Task 2).
- Produces: nothing new.

- [ ] **Step 1: Route the Dashboard VM through the singleton**

Change line 11 from:

```swift
  @StateObject private var vibeCheckViewModel = VibeCheckViewModel()
```

to:

```swift
  @StateObject private var vibeCheckViewModel = VibeCheckViewModel.shared
```

- [ ] **Step 2: Add the detection toggle as the first always-visible toolbar button**

In `toolbarButtons` (starts line 152), insert the detection button **before** the existing notification bell button (before the `// Notification toggle (always visible)` comment):

```swift
    // Detection toggle (always visible)
    Button {
      Task { await vibeCheckViewModel.toggleDetection() }
    } label: {
      Image(systemName: vibeCheckViewModel.isDetectionEnabled ? "eye.fill" : "eye.slash")
    }
    .help(vibeCheckViewModel.isDetectionEnabled ? "Stop VibeCheck detection" : "Start VibeCheck detection")

```

- [ ] **Step 3: Build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Views/Dashboard/Dashboard.swift
git commit -m "feat(vibecheck): shared VM + toolbar detection toggle in Dashboard"
```

---

### Task 5: MenuBarView — observe `.shared` + detection row

**Files:**
- Modify: `vibecare/Views/PlaceholderViews.swift`

**Interfaces:**
- Consumes: `VibeCheckViewModel.shared`, `isDetectionEnabled`, `toggleDetection()` (Task 2); existing `MenuBarButton` component.
- Produces: nothing new.

- [ ] **Step 1: Observe the shared detection VM in `MenuBarView`**

In `MenuBarView` add a state object alongside the existing `notificationPolicy` (after line 177):

```swift
  @StateObject private var vibeCheck = VibeCheckViewModel.shared
```

- [ ] **Step 2: Add a detection `MenuBarButton` in the action section**

In the "Action buttons section" `VStack(spacing: 2)` (starts line 235), add the detection row immediately after the existing notifications `MenuBarButton` (after its closing `)` on line 240):

```swift
        MenuBarButton(
          icon: vibeCheck.isDetectionEnabled ? "video.fill" : "video.slash",
          title: vibeCheck.isDetectionEnabled ? "Detection: On" : "Turn On Detection",
          action: { Task { await vibeCheck.toggleDetection() } }
        )
```

- [ ] **Step 3: Build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Views/PlaceholderViews.swift
git commit -m "feat(vibecheck): menu-bar detection toggle"
```

---

### Task 6: App startup — auto-resume detection

**Files:**
- Modify: `vibecare/App.swift`

**Interfaces:**
- Consumes: `VibeCheckViewModel.shared.resumeIfEnabled()` (Task 2).
- Produces: nothing new.

- [ ] **Step 1: Call `resumeIfEnabled()` in the startup Task**

In `App.swift`, inside the `.onAppear` Task (currently lines 33–40), add the resume call after `await appState.loadInitialData()`:

```swift
                .onAppear {
                    // Load initial data
                    Task {
                        await appState.loadInitialData()

                        // Auto-resume VibeCheck detection if it was on at last quit.
                        await VibeCheckViewModel.shared.resumeIfEnabled()

                        // VibeNotify requires no permission setup - ready to use!
                        logger.info("App loaded - VibeNotify ready for notifications")
                    }
                }
```

- [ ] **Step 2: Build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/App.swift
git commit -m "feat(vibecheck): auto-resume detection on launch"
```

---

### Task 7: Full verification + handoff

**Files:** none (verification only).

- [ ] **Step 1: Run the full unit test suite**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests`
Expected: PASS — all `DetectionPreferenceTests` (new) and `VibeCheckViewModelTests` (existing) green.

- [ ] **Step 2: SwiftPM sanity build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 3: Hand off to the user for the manual run**

Ask the user to run the app (`just swift-run`) and confirm:
1. Toggle detection **on** from the toolbar eye button → camera starts, VibeCheck tab shows live preview.
2. Navigate to Schedules/Routines → detection keeps running; trigger a BFRB gesture and confirm the VibeNotify nudge still fires from another tab.
3. Toggle **off** from the menu-bar "Detection: On" row → camera stops; VibeCheck tab shows the "Detection is off" prompt.
4. Toggle on, **quit** the app, **relaunch** → detection auto-resumes (camera on) after load.
5. (If feasible) deny camera permission and toggle on → flag resolves back to off, no crash/loop; permission view shows.

- [ ] **Step 4: Final review of staged scope**

Confirm only the feature files were touched across the commits. Do **not** stage unrelated pre-existing working-tree changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `plugins/vibecheck/vibecheck` stray binary). This plan doc may be committed separately if the user wants it tracked.

---

## Notes on decisions carried from the spec

- Persist & auto-resume; denied permission on resume resolves the flag back to off (Task 2 `setDetection` + Task 6).
- Toggle in **both** toolbar and menu bar, driving one shared state (Tasks 4, 5).
- Menu-bar header badge stays tied to notifications; detection gets its own row (Task 5).
- No camera-hardware abstraction/fake; only the pure `DetectionPreference` is unit-tested (Task 1). Camera start/stop, resume, and UI wiring are verified by build + manual run (Task 7).
- No new global hotkey (out of scope; possible follow-up).
