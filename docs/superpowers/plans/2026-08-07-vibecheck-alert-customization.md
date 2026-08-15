# VibeCheck Alert Customization Implementation Plan (REUSE-FIRST)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-behavior customization of the VibeCheck detection alert (icon, title, message, position, size, moveable, screen blur + intensity, auto-dismiss), in a collapsed "Advanced: Alert Appearance" tabbed section of the VibeCheck controls pane; settings persist — built by **reusing** the existing notification stack, not a parallel one.

**Architecture:** Reuse `NotificationPreferences` (existing `@Observable`, `Codable` model) as the per-behavior config, one per `BFRBBehavior` seeded from `.default`. A `@MainActor DetectionAlertPreferencesStore.shared` persists `[behaviorRawValue: NotificationPreferences]` as a JSON blob in UserDefaults, auto-saving via an encoded-snapshot `onChange`. Extract `showScheduleNotification`'s builder core into a shared `showNotification(...)` and route both schedule and the new `showBFRBAlert` through it (deleting the bespoke `BFRBAlertView`/`OverlayWindowManager` path). Reuse `NotificationCustomizationView` (lightly generalized with an injectable variables-hint + preview action) inside a per-behavior tabbed `VibeCheckAlertSettingsView`.

**Tech Stack:** SwiftUI (macOS 15+), swift-testing, UserDefaults + Codable, VibeNotify builder, `SVGView` (existing dep). Tests via xcodebuild; app builds via `just swift-build`.

## Global Constraints

- Platform macOS 15+; SwiftUI client only. No backend/proto changes. Do **not** edit `VCStubs/`.
- **Reuse, do not reinvent.** Use `NotificationPreferences` (`Models/NotificationPreferences.swift`) as the model — do NOT create a parallel model. Reuse `showScheduleNotification`'s builder logic and `NotificationCustomizationView` (`Views/Schedules/NotificationCustomizationView.swift`).
- UserDefaults key for the per-behavior blob: `"vibecheck.alert.preferences"` (verbatim).
- Rendering: alerts render through the standard VibeNotify builder — SF-Symbol icon → card, custom SVG icon → card-less (same rule as schedule notifications). The bespoke `BFRBAlertView` is deleted.
- Schedule-notification behavior must not change: the editor generalization is default-preserving (new params default to today's behavior); the renderer extraction is behavior-preserving.
- `BFRBBehavior` (`Models/BFRB.swift`): `nailBiting/nosePicking/hairPulling`; `label`, `alertIcon` (SF Symbol), `nudge` are the per-behavior defaults. `VibeNotifyConfig.ordinal(_:)` builds the streak ordinal and stays.
- The detection alert stays priority `.critical`; keep the `NotificationPolicy.shared.isNotificationAllowed(priority:)` guard (in the shared `showNotification`).
- Do NOT `git reset --hard` — the working tree has unrelated pre-existing uncommitted changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `docs/ideas.org`, stray `plugins/vibecheck/vibecheck`) that must be preserved. Remove obsolete files with `git rm`.
- Tests: swift-testing in `vibecareTests/` (auto-included). Run the **whole target** (the granular `-only-testing:vibecareTests/Name` selector matches 0 tests — top-level `@Test` funcs have no suite type): `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests`. Existing `VibeCheckViewModelTests` + `DetectionPreferenceTests` must stay green.
- ⚠️ Case-insensitive FS: sources on disk at lowercase `.../vibecare/…`; git tracks the group under capital `.../VibeCare/VibeCare/…`. Create/edit where files exist; `git add` and verify with `git status`.
- All paths below are relative to `clients/macos-swift/VibeCare/`.

---

### Task 1: Remove the obsolete parallel model + store

**Files:**
- Delete: `vibecare/Models/DetectionAlertPreferences.swift`
- Delete: `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`
- Delete: `vibecareTests/DetectionAlertPreferencesTests.swift`

**Interfaces:**
- Consumes: nothing. Produces: nothing (removal only). Nothing else references these files yet (`showBFRBAlert`/`BFRBAlertView` are untouched in this task and still use the old path).

- [ ] **Step 1: Confirm no references before deleting**

Run: `grep -rn "DetectionAlertPreferences\|DetectionAlertAppearance\|DetectionAlertBehaviorPrefs\|DetectionAlertIcon" vibecare vibecareTests --include="*.swift" | grep -v VCStubs`
Expected: matches ONLY inside the three files being deleted. If anything else references them, STOP and report (something unexpected depends on them).

- [ ] **Step 2: Delete the files**

```bash
git rm clients/macos-swift/VibeCare/VibeCare/Models/DetectionAlertPreferences.swift \
       clients/macos-swift/VibeCare/VibeCare/Services/Detection/DetectionAlertPreferencesStore.swift \
       clients/macos-swift/VibeCare/vibecareTests/DetectionAlertPreferencesTests.swift
git status   # if git reports different (lowercase) tracked paths, git rm those instead
```

- [ ] **Step 3: Build + test to confirm nothing broke**

Run: `just swift-build` then `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: build succeeds; `** TEST SUCCEEDED **` (existing suites still green; the deleted tests are gone).

- [ ] **Step 4: Commit**

```bash
git commit -m "revert(vibecheck): drop parallel DetectionAlertPreferences model/store

Superseded by reusing NotificationPreferences (see revised design)."
```

---

### Task 2: `DetectionAlertPreferencesStore` over `NotificationPreferences` (TDD)

**Files:**
- Create: `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`
- Test: `vibecareTests/DetectionAlertPreferencesStoreTests.swift`

**Interfaces:**
- Consumes: `NotificationPreferences` (existing; `Codable`, `.default`), `BFRBBehavior`.
- Produces:
  - `@MainActor final class DetectionAlertPreferencesStore: ObservableObject` with `static let shared`, `@Published var byBehavior: [String: NotificationPreferences]`, `init(defaults: UserDefaults = .standard)`, `func preferences(for b: BFRBBehavior) -> NotificationPreferences`, `var encodedSnapshot: Data`, `func persist()`.

- [ ] **Step 1: Write the failing tests**

Create `vibecareTests/DetectionAlertPreferencesStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import vibecare

@MainActor
@Test func preferencesForSeedsFromDefaultAndReturnsStableInstance() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let store = DetectionAlertPreferencesStore(defaults: defaults)
    let first = store.preferences(for: .nailBiting)
    // seeded from .default
    #expect(first.position == NotificationPreferences.default.position)
    #expect(first.width == NotificationPreferences.default.width)
    // stable instance on repeat access (so the editor binds one object)
    #expect(store.preferences(for: .nailBiting) === first)
}

@MainActor
@Test func persistedEditsAreReadBackByASecondStore() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let writer = DetectionAlertPreferencesStore(defaults: defaults)
    let prefs = writer.preferences(for: .nosePicking)
    prefs.position = .bottomRight
    prefs.title = "Hands away"
    writer.persist()

    let reader = DetectionAlertPreferencesStore(defaults: defaults)
    let read = reader.preferences(for: .nosePicking)
    #expect(read.position == .bottomRight)
    #expect(read.title == "Hands away")
}

@MainActor
@Test func encodedSnapshotDecodesToEqualMap() throws {
    let store = DetectionAlertPreferencesStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    _ = store.preferences(for: .hairPulling)   // materialize one entry
    let decoded = try JSONDecoder().decode([String: NotificationPreferences].self, from: store.encodedSnapshot)
    #expect(decoded == store.byBehavior)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL — `DetectionAlertPreferencesStore` not defined.

- [ ] **Step 3: Write the store**

Create `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`:

```swift
import Foundation
import SwiftUI

/// App-wide, persisted store for per-behavior VibeCheck detection-alert
/// preferences. Reuses `NotificationPreferences` (the same model schedule
/// notifications use). The Advanced settings UI binds to `.shared`, and
/// `showBFRBAlert` reads `preferences(for:)` at fire time.
///
/// `NotificationPreferences` is a reference type, so field edits mutate in place
/// and won't trigger value-based change detection. Auto-save is driven by the
/// settings view observing `encodedSnapshot` (whose read touches every field, so
/// Observation re-fires on any edit) and calling `persist()`.
@MainActor
final class DetectionAlertPreferencesStore: ObservableObject {
    static let shared = DetectionAlertPreferencesStore()

    @Published var byBehavior: [String: NotificationPreferences]

    private let defaults: UserDefaults
    private let key = "vibecheck.alert.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: NotificationPreferences].self, from: data) {
            self.byBehavior = decoded
        } else {
            self.byBehavior = [:]
        }
    }

    /// Get-or-create the prefs for `b`, seeded from `.default`. Inserts on first
    /// access so the editor binds a stable instance across renders.
    func preferences(for b: BFRBBehavior) -> NotificationPreferences {
        if let existing = byBehavior[b.rawValue] { return existing }
        let seeded = NotificationPreferences.default.copy()
        byBehavior[b.rawValue] = seeded
        return seeded
    }

    /// Encoded snapshot of the whole map. Reading it touches every field of every
    /// `NotificationPreferences`, so a SwiftUI `onChange(of:)` on this value
    /// re-fires on ANY field edit (Observation tracks the reads) — that is how the
    /// settings view triggers reliable auto-save.
    var encodedSnapshot: Data { (try? JSONEncoder().encode(byBehavior)) ?? Data() }

    func persist() {
        guard let data = try? JSONEncoder().encode(byBehavior) else { return }
        defaults.set(data, forKey: key)
    }
}
```

> `NotificationPreferences.default.copy()` — the store must seed each behavior with
> its OWN instance (not share the `.default` singleton). If `NotificationPreferences`
> has no `copy()`, add one in `Models/NotificationPreferences.swift`:
> `func copy() -> NotificationPreferences { NotificationPreferences(bundledIconId: bundledIconId, svgPath: svgPath, svgWidth: svgWidth, svgHeight: svgHeight, title: title, message: message, position: position, width: width, height: height, moveable: moveable, autoDismissAfter: autoDismissAfter, screenBlurEnabled: screenBlurEnabled, screenBlurIntensity: screenBlurIntensity) }`
> (all fields via the existing memberwise `init`). Commit that helper with this task.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`; the 3 new store tests pass.

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Services/Detection/DetectionAlertPreferencesStore.swift \
        clients/macos-swift/VibeCare/vibecareTests/DetectionAlertPreferencesStoreTests.swift \
        clients/macos-swift/VibeCare/VibeCare/Models/NotificationPreferences.swift
git status
git commit -m "feat(vibecheck): per-behavior alert prefs store reusing NotificationPreferences"
```

---

### Task 3: Shared renderer + `showBFRBAlert` reusing the VibeNotify builder

**Files:**
- Modify: `vibecare/Services/VibeNotifyConfiguration.swift`
- Delete: `vibecare/Views/VibeCheck/BFRBAlertView.swift`

**Interfaces:**
- Consumes: `NotificationPreferences`, `DetectionAlertPreferencesStore.shared` (Task 2), `BFRBBehavior`, `NotificationPolicy`, `VibeNotify` builder, existing `ordinal(_:)`.
- Produces:
  - `private static func showNotification(preferences:title:message:defaultSystemIcon:priority:) -> UUID?` (shared builder core).
  - `showBFRBAlert(behavior:count:preferences:)` with `preferences: NotificationPreferences = DetectionAlertPreferencesStore.shared.preferences(for: behavior)`.
  - `showScheduleNotification(...)` unchanged externally (now delegates to `showNotification`).

- [ ] **Step 1: Extract the shared `showNotification` builder core**

In `VibeNotifyConfiguration.swift`, add a private generic that contains the guard + icon-selection + builder customizations currently inside `showScheduleNotification` (lines ~49–145). It takes already-resolved `title`/`message` and a `defaultSystemIcon`:

```swift
@MainActor
@discardableResult
private static func showNotification(
    preferences prefs: NotificationPreferences,
    title: String,
    message: String,
    defaultSystemIcon: String,
    priority: NotificationPriority
) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else { return nil }

    var builder = VibeNotify.builder()

    // Icon: SVG (url/file) if configured, else the caller's default system icon.
    if let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize {
        if svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://") {
            if let url = URL(string: svgPath) {
                builder = builder.svgURL(url, size: svgSize)
            } else {
                builder = builder.icon(.system(defaultSystemIcon))
            }
        } else {
            builder = builder.svg(svgPath, size: svgSize)
        }
    } else {
        builder = builder.icon(.system(defaultSystemIcon))
    }

    builder = builder
        .title(title)
        .message(message)
        .moveable(prefs.moveable)
        .alwaysOnTop(true)
        .dismissOnScreenTap(true)
        .autoDismiss(after: prefs.autoDismissAfter ?? quickDismissDelay)

    if prefs.screenBlurEnabled {
        builder = builder.screenBlur(true, intensity: prefs.screenBlurIntensity.vibeNotifyIntensity)
    }

    switch prefs.position {
    case .center:      builder = builder.position(.center)
    case .topLeft:     builder = builder.position(.topLeft)
    case .topRight:    builder = builder.position(.topRight)
    case .bottomLeft:  builder = builder.position(.bottomLeft)
    case .bottomRight: builder = builder.position(.bottomRight)
    }

    if let width = prefs.width { builder = builder.width(CGFloat(width)) }
    if let height = prefs.height { builder = builder.height(CGFloat(height)) }

    return builder.show()
}
```

> Match the exact builder method names/behavior already in `showScheduleNotification`
> (the logging calls may be dropped in the extracted core). If any builder call
> differs, mirror what `showScheduleNotification` does today and note it in the report.

- [ ] **Step 2: Route `showScheduleNotification` through `showNotification`**

Replace `showScheduleNotification`'s builder body (keep its signature + the
`formatTitle/formatMessage` resolution) with a delegation:

```swift
    let title = prefs.formatTitle(scheduleName: scheduleName, routineName: routineName)
    let message = prefs.formatMessage(scheduleName: scheduleName, routineName: routineName, scheduledTime: scheduledTime)
    return showNotification(preferences: prefs, title: title, message: message,
                            defaultSystemIcon: "bell.badge.fill", priority: priority)
```

(The existing `guard NotificationPolicy…` at the top of `showScheduleNotification`
is now redundant with the one in `showNotification` — remove the outer one, or keep
it; either is fine as long as behavior is unchanged. Prefer removing the duplicate.)

- [ ] **Step 3: Replace `showBFRBAlert` and add `String.nonEmpty`**

Replace the whole `showBFRBAlert(behavior:count:)` (and its `OverlayWindowManager`
body + `bfrbAlertDuration`) with:

```swift
@MainActor
@discardableResult
static func showBFRBAlert(
    behavior: BFRBBehavior,
    count: Int,
    preferences: NotificationPreferences = DetectionAlertPreferencesStore.shared.preferences(for: behavior)
) -> UUID? {
    let title = preferences.title?.nonEmpty ?? behavior.label
    let base = preferences.message?.nonEmpty ?? behavior.nudge
    let message = "\(base)\n\(ordinal(count)) nudge today"
    return showNotification(preferences: preferences, title: title, message: message,
                            defaultSystemIcon: behavior.alertIcon, priority: .critical)
}
```

Add (near the top of the file, if not already present):

```swift
private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
```

Delete `bfrbAlertDuration` if now unused.

- [ ] **Step 4: Delete `BFRBAlertView`**

```bash
git rm clients/macos-swift/VibeCare/VibeCare/Views/VibeCheck/BFRBAlertView.swift
```

Confirm no remaining references: `grep -rn "BFRBAlertView\|OverlayWindowManager" vibecare --include="*.swift" | grep -v VCStubs` → expect no matches in app code (only the now-removed usages). If `OverlayWindowManager` is still referenced elsewhere, leave that usage alone.

- [ ] **Step 5: Build + test**

Run: `just swift-build` then `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: build succeeds; `** TEST SUCCEEDED **`. `showBFRBAlert`/`showScheduleNotification` have no unit tests — verified by build + existing tests + manual run.

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Services/VibeNotifyConfiguration.swift
git rm clients/macos-swift/VibeCare/VibeCare/Views/VibeCheck/BFRBAlertView.swift 2>/dev/null; true
git status
git commit -m "feat(vibecheck): render detection alert via shared VibeNotify builder; drop BFRBAlertView"
```

---

### Task 4: Generalize the editor + advanced settings UI

**Files:**
- Modify: `vibecare/Views/Schedules/NotificationCustomizationView.swift`
- Create: `vibecare/Views/VibeCheck/VibeCheckAlertSettingsView.swift`
- Modify: `vibecare/Views/VibeCheck/VibeCheckControlsPanel.swift`

**Interfaces:**
- Consumes: `NotificationCustomizationView` (generalized), `DetectionAlertPreferencesStore.shared` (Task 2), `showBFRBAlert(...preferences:)` (Task 3), `BFRBBehavior.allCases`.
- Produces: `VibeCheckAlertSettingsView`; two new **optional, default-preserving** params on `NotificationCustomizationView`.

- [ ] **Step 1: Add optional injection points to `NotificationCustomizationView`**

Add two stored properties with defaults that preserve current schedule behavior:

```swift
  var variablesHint: String? = nil
  var onPreview: (() -> Void)? = nil
```

In `messageCustomizationSection`, replace the hard-coded hint text with:

```swift
      Text(variablesHint ?? "Available variables: {scheduleName}, {routineName}, {time}")
```

In `previewSection`, change the button action from `showPreviewNotification()` to:

```swift
        if let onPreview { onPreview() } else { showPreviewNotification() }
```

(Schedule call sites pass neither param — behavior unchanged.)

- [ ] **Step 2: Create `VibeCheckAlertSettingsView`**

Create `vibecare/Views/VibeCheck/VibeCheckAlertSettingsView.swift`:

```swift
import SwiftUI

/// Advanced, per-behavior customization for the VibeCheck detection alert.
/// Reuses `NotificationCustomizationView`; edits persist via the shared store.
struct VibeCheckAlertSettingsView: View {
    @StateObject private var store = DetectionAlertPreferencesStore.shared
    @State private var selected: BFRBBehavior = .nailBiting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Behavior", selection: $selected) {
                ForEach(BFRBBehavior.allCases) { b in Text(b.label).tag(b) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            NotificationCustomizationView(
                preferences: binding(for: selected),
                scheduleName: selected.label,
                scheduleNotes: selected.nudge,
                variablesHint: "Title & message default to this behavior's label and nudge. \"Nth nudge today\" is appended automatically.",
                onPreview: {
                    VibeNotifyConfig.showBFRBAlert(
                        behavior: selected, count: 1,
                        preferences: store.preferences(for: selected))
                }
            )
        }
        // Reliable auto-save: reading encodedSnapshot tracks every field (Observation),
        // so this fires on any edit to any behavior's prefs.
        .onChange(of: store.encodedSnapshot) { _, _ in store.persist() }
    }

    private func binding(for b: BFRBBehavior) -> Binding<NotificationPreferences> {
        Binding(
            get: { store.preferences(for: b) },
            set: { store.byBehavior[b.rawValue] = $0 }
        )
    }
}
```

- [ ] **Step 3: Wire the disclosure into `VibeCheckControlsPanel`**

In `VibeCheckControlsPanel.swift`, add `@State private var showAdvanced = false` to the struct, and add a new `Section` at the end of the `Form` (after the `Session` section):

```swift
            Section {
                DisclosureGroup("Advanced: Alert Appearance", isExpanded: $showAdvanced) {
                    VibeCheckAlertSettingsView()
                        .padding(.top, 4)
                }
            }
```

- [ ] **Step 4: Build**

Run: `just swift-build`
Expected: build succeeds.

- [ ] **Step 5: Run the full test target (guards schedule + existing tests)**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/VibeCare/Views/Schedules/NotificationCustomizationView.swift \
        clients/macos-swift/VibeCare/VibeCare/Views/VibeCheck/VibeCheckAlertSettingsView.swift \
        clients/macos-swift/VibeCare/VibeCare/Views/VibeCheck/VibeCheckControlsPanel.swift
git status
git commit -m "feat(vibecheck): reuse NotificationCustomizationView for per-behavior alert settings"
```

---

### Task 5: Full verification + handoff

**Files:** none (verification only).

- [ ] **Step 1: Full unit test suite**

Run: `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Executed"`
Expected: `** TEST SUCCEEDED **` — new store tests + existing `VibeCheckViewModelTests`/`DetectionPreferenceTests` green.

- [ ] **Step 2: SwiftPM sanity build**

Run: `just swift-build`
Expected: succeeds, no new warnings.

- [ ] **Step 3: Hand off to the user for the manual run**

Ask the user to run the app (`just swift-run`), open VibeCheck → controls → expand "Advanced: Alert Appearance", and confirm:
1. Behavior tabs switch (Nail-biting / Nose-picking / Hair-pulling); the reused editor shows presets, icon, message, position, size, behavior controls.
2. **Preview** fires the detection alert reflecting current settings (no camera needed). With an SF-Symbol/default icon it's a card; with a custom SVG it's card-less.
3. Editing title/message changes the previewed alert; empty reverts to the behavior's label/nudge; "Nth nudge today" is appended.
4. Presets, custom SVG (+ size), position, size, moveable, blur+intensity, auto-dismiss all affect Preview.
5. Settings are per-behavior (switching tabs shows independent configs).
6. Quit and relaunch → settings persist.
7. Schedule notification editor still works unchanged (open a schedule's Send Notification action → its editor + Preview behave as before).
8. Trigger a real detection (camera) → the live alert reflects saved settings.

- [ ] **Step 4: Final scope check**

Confirm only the feature files were committed across Tasks 1-4. Do **not** stage unrelated pre-existing working-tree changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `docs/ideas.org`, `plugins/vibecheck/vibecheck`).

---

## Notes on decisions carried from the spec

- Reuse `NotificationPreferences`, `showScheduleNotification`'s builder core, and `NotificationCustomizationView` — no parallel model/renderer/editor (Tasks 1-4).
- Per-behavior full `NotificationPreferences` (seeded from `.default`); Default/Minimal/Prominent presets are the "shared" starting points (Task 2/4).
- Standard renderer: SF-Symbol → card, custom SVG → card-less; `BFRBAlertView` deleted (Task 3).
- Auto-save via the encoded-snapshot `onChange` trick (reliable despite `NotificationPreferences` being a reference type) (Tasks 2, 4).
- Schedule behavior preserved: editor params default-preserving; renderer extraction behavior-preserving (Tasks 3, 4).
- Only the store/persistence is unit-tested; renderer, editor, SVG, Preview verified by build + manual run.
