# VibeCheck Alert Customization — Design & Spec

> Design doc. Date: 2026-08-07. Branch: `ft/plugin/vibecheck`.
> Client-only (SwiftUI macOS app under `clients/macos-swift/VibeCare/`).
> Self-contained: written to be executed in a **fresh session** with no prior chat context.

## Problem / Goal

The VibeCheck detection alert (shown on a confirmed BFRB detection) is currently
**hardcoded**: `VibeNotifyConfig.showBFRBAlert(behavior:count:)` builds a fixed
`OverlayWindowManager.Configuration` (center, 480×300, moveable, blur `.medium`,
6 s auto-dismiss) and renders `BFRBAlertView` with a per-behavior SF Symbol icon,
the behavior label, its nudge, and a streak line ("Nth nudge today").

Schedule notifications, by contrast, already have rich per-notification
customization (icon, message, position, size, moveable, screen blur + intensity,
auto-dismiss) via the `NotificationPreferences` model and the
`NotificationCustomizationView` editor.

**Goal:** give advanced users the same class of customization for the detection
alert, exposed as a collapsed **"Advanced: Alert Appearance"** section in the
VibeCheck controls pane. Customization is **per behavior** (tabbed: Nail-biting |
Nose-picking | Hair-pulling), with a **shared appearance default** and a
**per-behavior override** escape hatch. Settings **persist** across launches.

## Key facts about the current code (verified)

- `BFRBBehavior` (`vibecare/Models/BFRB.swift`) — `enum … : String, CaseIterable,
  Sendable, Identifiable`, cases `nailBiting, nosePicking, hairPulling`. Provides
  `label` ("Nail-biting"/"Nose-picking"/"Hair-pulling"), `alertIcon` (SF Symbol:
  `hand.raised.fill`/`nose.fill`/`comb.fill`), and `nudge` (encouraging message).
  These are the per-behavior **defaults**.
- `VibeNotifyConfig.showBFRBAlert(behavior:count:)`
  (`vibecare/Services/VibeNotifyConfiguration.swift`) — `@MainActor
  @discardableResult static func … -> UUID?`. Guards on
  `NotificationPolicy.shared.isNotificationAllowed(priority: .critical)`, then:
  ```swift
  let config = OverlayWindowManager.Configuration(
      position: .center, width: 480, height: 300,
      isMoveable: true, alwaysOnTop: true,
      screenBlur: true, screenBlurIntensity: .medium,
      dismissOnScreenTap: true)
  _ = OverlayWindowManager.shared.show(id: id, configuration: config) {
      BFRBAlertView(behavior: behavior, count: count) { OverlayWindowManager.shared.dismiss(id: id) }
  }
  // custom-content window has no built-in timer; schedule dismiss after bfrbAlertDuration (6.0s)
  ```
  Also exposes `static func ordinal(_:) -> String` (used by the alert view).
- `BFRBAlertView` (`vibecare/Views/VibeCheck/BFRBAlertView.swift`) — card-less
  `View` with `let behavior: BFRBBehavior; let count: Int; let onDismiss: () -> Void`.
  Renders `Image(systemName: behavior.alertIcon)`, `Text(behavior.label)`, and
  `Text("\(behavior.nudge)\n\(VibeNotifyConfig.ordinal(count)) nudge today")`.
  Light/dark text handling via `colorScheme`.
- `NotificationPosition` and `BlurIntensity` enums
  (`vibecare/Models/NotificationPreferences.swift`) — both `String, Codable,
  CaseIterable`, with `displayName` and `iconName`. `BlurIntensity` has cases
  `light/medium/heavy`; `VibeNotifyConfiguration.swift` already defines
  `extension BlurIntensity { var vibeNotifyIntensity: ScreenBlurIntensity }`.
  **Reuse these — do not define new position/blur enums.**
- `NotificationPreferences` (same file) — the schedule model; has `static let
  default/minimal/prominent` presets with position/width/height/moveable/
  autoDismiss/blur values we mirror for VibeCheck's shared-appearance presets.
- `SVGView` is already a package dependency (`import SVGView`), used by
  `NotificationCustomizationView`. Use it to render a custom-SVG icon.
- `VibeCheckControlsPanel` (`vibecare/Views/VibeCheck/VibeCheckControlsPanel.swift`)
  — the detail pane, a `Form` with `@ObservedObject var viewModel:
  VibeCheckViewModel` and sections Detection / Sensitivity / Alerts / Session.
  This is where the new disclosure section is added.
- Established persistence pattern: `DetectionPreference`
  (`vibecare/Services/Detection/DetectionPreference.swift`) — a `UserDefaults`-
  backed struct behind a `…Storing` protocol, `init(defaults: UserDefaults =
  .standard)`; unit-tested in `vibecareTests/DetectionPreferenceTests.swift` with
  an ephemeral `UserDefaults(suiteName:)`. Established singleton pattern:
  `NotificationPolicy.shared`, `AppState.shared` (`@MainActor` `ObservableObject`
  with `static let shared`).
- Tests: swift-testing (`import Testing`, `@Test`, `#expect`, `@testable import
  vibecare`) in `vibecareTests/` (a `PBXFileSystemSynchronizedRootGroup`, so new
  files auto-include). **Run via xcodebuild, NOT the granular per-suite selector**
  (top-level `@Test` funcs have no enclosing suite type, so
  `-only-testing:vibecareTests/SomeName` matches 0 tests — run the whole target):
  `xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination
  'platform=macOS' -only-testing:vibecareTests`. App also builds via `just
  swift-build`.
- ⚠️ Case-insensitive-FS quirk: app sources are on disk at lowercase
  `clients/macos-swift/VibeCare/vibecare/…` but git tracks them under capital
  `…/VibeCare/VibeCare/…`. Edit files where they exist on disk; `git add` and
  verify with `git status` that the intended file is staged.

## Decisions (confirmed with the user)

- **Placement:** a collapsed "Advanced: Alert Appearance" disclosure at the bottom
  of the existing `VibeCheckControlsPanel` (hidden by default).
- **Scope:** per behavior, presented as **tabs** (Nail-biting | Nose-picking |
  Hair-pulling).
- **Model:** one **shared** appearance applied to all alerts, plus a **per-behavior
  override** ("give option to override if possible"). Icon and message/title are
  always per-behavior.
- **Icon:** default is the per-behavior SF Symbol; override with a **custom SVG**
  file (path + width×height + Remove), mirroring the schedule editor's icon row.
  No bundled-icon catalog for VibeCheck.
- **Persist** to UserDefaults; auto-save on edit; auto-apply on next launch and to
  live detections.

## Design

### 1. Data model (new file `vibecare/Models/DetectionAlertPreferences.swift`, `Codable`)

```swift
struct DetectionAlertAppearance: Codable, Equatable {
    var position: NotificationPosition
    var width: CGFloat
    var height: CGFloat
    var moveable: Bool
    var screenBlurEnabled: Bool
    var screenBlurIntensity: BlurIntensity
    var autoDismissAfter: TimeInterval

    /// Exactly today's hardcoded values — changing detection behavior must be
    /// opt-in, so the shipped default reproduces the current alert.
    static let `default` = DetectionAlertAppearance(
        position: .center, width: 480, height: 300, moveable: true,
        screenBlurEnabled: true, screenBlurIntensity: .medium, autoDismissAfter: 6.0)

    // Mirror the schedule presets for the Quick Presets row.
    static let minimal  = DetectionAlertAppearance(position: .topRight, width: 350, height: 150,
        moveable: false, screenBlurEnabled: false, screenBlurIntensity: .light, autoDismissAfter: 5.0)
    static let prominent = DetectionAlertAppearance(position: .center, width: 500, height: 320,
        moveable: true, screenBlurEnabled: true, screenBlurIntensity: .heavy, autoDismissAfter: 8.0)
}

/// Resolved icon for the alert view: default SF Symbol or a custom SVG.
enum DetectionAlertIcon: Equatable {
    case symbol(String)          // SF Symbol name (per-behavior default)
    case svg(path: String, size: CGSize)
}

struct DetectionAlertBehaviorPrefs: Codable, Equatable {
    var titleOverride: String?    // nil → behavior.label
    var messageOverride: String?  // nil → behavior.nudge
    var iconSVGPath: String?      // nil → behavior.alertIcon (SF Symbol)
    var iconSVGWidth: CGFloat?
    var iconSVGHeight: CGFloat?
    var overridesAppearance: Bool = false
    var appearance: DetectionAlertAppearance = .default  // used only when overridesAppearance
}

struct DetectionAlertPreferences: Codable, Equatable {
    var shared: DetectionAlertAppearance = .default
    var perBehavior: [String: DetectionAlertBehaviorPrefs] = [:]   // key = behavior.rawValue

    // Pure resolvers (unit-tested; no UIKit/AVFoundation):
    func effectiveAppearance(for b: BFRBBehavior) -> DetectionAlertAppearance {
        let p = perBehavior[b.rawValue]
        return (p?.overridesAppearance == true) ? p!.appearance : shared
    }
    func effectiveTitle(for b: BFRBBehavior) -> String {
        perBehavior[b.rawValue]?.titleOverride?.nonEmpty ?? b.label
    }
    func effectiveMessage(for b: BFRBBehavior) -> String {
        perBehavior[b.rawValue]?.messageOverride?.nonEmpty ?? b.nudge
    }
    func effectiveIcon(for b: BFRBBehavior) -> DetectionAlertIcon {
        if let path = perBehavior[b.rawValue]?.iconSVGPath?.nonEmpty {
            let w = perBehavior[b.rawValue]?.iconSVGWidth ?? 64
            let h = perBehavior[b.rawValue]?.iconSVGHeight ?? 64
            return .svg(path: path, size: CGSize(width: w, height: h))
        }
        return .symbol(b.alertIcon)
    }
}
```
(`String.nonEmpty` — a tiny helper returning `nil` for empty/whitespace strings;
define privately in the model file if not already present.)

### 2. Persistence (new file `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`)

```swift
@MainActor
final class DetectionAlertPreferencesStore: ObservableObject {
    static let shared = DetectionAlertPreferencesStore()
    @Published var preferences: DetectionAlertPreferences { didSet { persist() } }

    private let defaults: UserDefaults
    private let key = "vibecheck.alert.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(DetectionAlertPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = DetectionAlertPreferences()
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }
    // Convenience mutators for the UI to edit a single behavior's prefs
    // (get-or-create the entry, mutate, reassign to trigger didSet).
    func behavior(_ b: BFRBBehavior) -> DetectionAlertBehaviorPrefs { preferences.perBehavior[b.rawValue] ?? DetectionAlertBehaviorPrefs() }
    func setBehavior(_ b: BFRBBehavior, _ prefs: DetectionAlertBehaviorPrefs) { preferences.perBehavior[b.rawValue] = prefs }
}
```
Tests inject an ephemeral `UserDefaults(suiteName:)`.

### 3. Alert resolution + rendering

**`BFRBAlertView`** gains resolved inputs so it no longer reads behavior defaults
directly:
```swift
struct BFRBAlertView: View {
    let title: String
    let message: String        // already includes the nudge; streak appended by the view
    let icon: DetectionAlertIcon
    let count: Int
    let onDismiss: () -> Void
    // body: render icon (Image(systemName:) for .symbol, SVGView for .svg at its size),
    //       Text(title), Text("\(message)\n\(VibeNotifyConfig.ordinal(count)) nudge today")
}
```

**`showBFRBAlert`** resolves from preferences (with an injectable param for Preview):
```swift
@MainActor @discardableResult
static func showBFRBAlert(
    behavior: BFRBBehavior,
    count: Int,
    preferences: DetectionAlertPreferences = DetectionAlertPreferencesStore.shared.preferences
) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: .critical) else { return nil }
    let appearance = preferences.effectiveAppearance(for: behavior)
    let id = UUID()
    let config = OverlayWindowManager.Configuration(
        position: appearance.position.overlayPosition,     // NotificationPosition → OverlayWindowManager position
        width: appearance.width, height: appearance.height,
        isMoveable: appearance.moveable, alwaysOnTop: true,
        screenBlur: appearance.screenBlurEnabled,
        screenBlurIntensity: appearance.screenBlurIntensity.vibeNotifyIntensity,
        dismissOnScreenTap: true)
    _ = OverlayWindowManager.shared.show(id: id, configuration: config) {
        BFRBAlertView(
            title: preferences.effectiveTitle(for: behavior),
            message: preferences.effectiveMessage(for: behavior),
            icon: preferences.effectiveIcon(for: behavior),
            count: count) { OverlayWindowManager.shared.dismiss(id: id) }
    }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(appearance.autoDismissAfter))
        OverlayWindowManager.shared.dismiss(id: id)
    }
    return id
}
```
A small `NotificationPosition.overlayPosition` computed property maps to
`OverlayWindowManager.WindowPosition` (verified type: cases `center/topLeft/
topRight/bottomLeft/bottomRight` map 1:1; `Configuration.position` is
`WindowPosition?` and `Configuration.screenBlurIntensity` is `ScreenBlurIntensity?`,
supplied via the existing `BlurIntensity.vibeNotifyIntensity`). Add the mapping
next to the model or in `VibeNotifyConfiguration.swift`.

### 4. UI — "Advanced: Alert Appearance" disclosure

New file `vibecare/Views/VibeCheck/VibeCheckAlertSettingsView.swift` — the
disclosure body, bound to `@ObservedObject var store: DetectionAlertPreferencesStore`
(passed `.shared`). Added to `VibeCheckControlsPanel` as a new `Section` containing
a `DisclosureGroup("Advanced: Alert Appearance", isExpanded:)` collapsed by default
(`@State private var showAdvanced = false`).

Contents:
- **Quick Presets** — buttons Default / Minimal / Prominent → set `store.preferences.shared`
  to the matching `DetectionAlertAppearance` preset.
- **Behavior tabs** — `Picker` (`.segmented`) over `BFRBBehavior.allCases` bound to
  `@State private var selected: BFRBBehavior`.
- Per selected behavior (edits `store.behavior(selected)` then `store.setBehavior`):
  - **Icon** — shows the default SF Symbol (`Image(systemName: selected.alertIcon)`)
    or, if a custom SVG is set, an `SVGView` + filename + W×H fields + Remove.
    A "Choose SVG…" button opens `.fileImporter` (UTType `.svg`) and stores the
    picked file path + a default 64×64 size.
  - **Title** `TextField` (placeholder = `selected.label`).
  - **Message** `TextField` (placeholder = `selected.nudge`).
  - **"Override appearance for this behavior"** `Toggle` (`overridesAppearance`).
    When on, reveal that behavior's `appearance` controls (position picker, width/
    height sliders, moveable, blur toggle + intensity segmented, auto-dismiss slider);
    seed from `shared` the first time it's turned on.
- **Shared appearance** block (same appearance controls, editing `store.preferences.shared`)
  — applies to every behavior not overriding.
- **Preview** button → `VibeNotifyConfig.showBFRBAlert(behavior: selected, count: 1,
  preferences: store.preferences)` (uses current unsaved-to-disk in-memory state,
  which is already live in the store).
- **Reset to defaults** → `store.preferences = DetectionAlertPreferences()`.

The appearance controls (position picker, size sliders, blur toggle+intensity,
auto-dismiss) are used in two places (shared + per-behavior override), so extract a
small `AlertAppearanceControls(appearance: Binding<DetectionAlertAppearance>)`
subview in the same file to avoid duplication.

## Testing (TDD for the pure/persistence pieces)

New `vibecareTests/DetectionAlertPreferencesTests.swift` (swift-testing):
- **Codable round-trip:** encode a customized `DetectionAlertPreferences`, decode,
  `#expect` equal.
- **Persistence via store:** with an ephemeral `UserDefaults(suiteName:)`, a
  `DetectionAlertPreferencesStore` writes on edit and a second store over the same
  suite reads the persisted value back.
- **Resolvers:**
  - `effectiveAppearance` returns `shared` when `overridesAppearance == false`, and
    the behavior's `appearance` when `true`.
  - `effectiveTitle`/`effectiveMessage` return overrides when set and non-empty;
    fall back to `behavior.label`/`behavior.nudge` when nil or empty/whitespace.
  - `effectiveIcon` returns `.svg(path,size)` when a non-empty path is set, else
    `.symbol(behavior.alertIcon)`.
- **Regression guard:** `DetectionAlertAppearance.default` equals the previously
  hardcoded values (center, 480, 300, moveable true, blur true `.medium`, 6.0).

UI, `.fileImporter`, `SVGView` rendering, and the Preview button are verified by
`just swift-build` + xcodebuild build + manual run (Preview fires a real alert
with **no camera** needed). Existing `VibeCheckViewModelTests` and
`DetectionPreferenceTests` must stay green.

## Non-goals

- No refactor of the 652-line `NotificationCustomizationView` (schedule editor) — we
  mirror its vocabulary, not its code.
- No bundled-icon catalog for VibeCheck (custom SVG file or the default SF Symbol only).
- No change to detection geometry/sensitivity/policy, the streak logic, or the
  notification-mute policy (alert stays `.critical`).
- No per-behavior sound customization (out of scope; possible follow-up).
