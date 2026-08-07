# VibeCheck Alert Customization — Design & Spec (REUSE-FIRST)

> Design doc. Date: 2026-08-07. Branch: `ft/plugin/vibecheck`.
> Client-only (SwiftUI macOS app under `clients/macos-swift/VibeCare/`).
> **Revised** after review: reuse the existing notification stack instead of a
> parallel one. Self-contained for a fresh session.

## Problem / Goal

Let advanced users customize the VibeCheck detection alert (per behavior: icon,
title, message, position, size, moveable, screen blur + intensity, auto-dismiss),
exposed as a collapsed **"Advanced: Alert Appearance"** section (tabs per behavior)
in the VibeCheck controls pane. Settings persist across launches.

**Core principle: reuse, do not reinvent.** The app already has the full stack:
- `NotificationPreferences` (`Models/NotificationPreferences.swift`) — an
  `@Observable`, `Codable` model with icon (bundled/SVG + size), title, message,
  position, width/height, moveable, screen blur + intensity, auto-dismiss, and
  Default/Minimal/Prominent presets. **This is the model. Do not create another.**
- `VibeNotifyConfig.showScheduleNotification(…preferences:)` — renders a
  `NotificationPreferences` through the VibeNotify builder. **Its builder core is
  the renderer; extract and share it.**
- `NotificationCustomizationView` (`Views/Schedules/NotificationCustomizationView.swift`)
  — the editor screen (presets, icon, message, position, size, behavior, preview),
  bound to a `NotificationPreferences`. **This is the settings UI; reuse it.**

## Rendering decision (confirmed with the user)

Reuse the standard VibeNotify renderer. The bespoke card-less `BFRBAlertView` +
`OverlayWindowManager` path is **deleted**. Consequence (accepted): an alert with
an SF-Symbol icon renders as the standard **card**; an alert with a **custom SVG**
icon renders **card-less** (SVG icons take the card-less path in VibeNotify) — the
same rendering rule schedule notifications already follow.

## What was wrong before (to undo)

Two commits landed a parallel model + store that duplicate `NotificationPreferences`:
- `0402c3e` — `vibecare/Models/DetectionAlertPreferences.swift` (+ its tests)
- `239cf25` — `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`

Both are **removed** in Task 1 (git rm; they are unpushed and unreferenced). Do
**not** `git reset --hard` — the working tree has unrelated pre-existing uncommitted
changes (`VCStubs/*`, `docs-site/*`, `docs/backlog.org`, `docs/ideas.org`, a stray
`plugins/vibecheck/vibecheck` binary) that must be preserved.

## Key facts about the current code (verified)

- `NotificationPreferences` — `@Observable final class`, `Codable, Equatable,
  Hashable`. Fields incl. `bundledIconId, svgPath, svgWidth/Height, title, message,
  position: NotificationPosition, width/height: CGFloat?, moveable, autoDismissAfter:
  TimeInterval?, screenBlurEnabled, screenBlurIntensity: BlurIntensity`. Statics
  `.default/.minimal/.prominent`, `presets`/`presetNames`, and `formatTitle/
  formatMessage` (schedule-template replacement). Being a **reference type**, field
  edits (`prefs.width = x`) mutate in place — value-based `onChange` will NOT fire
  on field edits (only on whole-object reassignment). Persistence must account for
  this (see §Persistence).
- `NotificationCustomizationView(preferences: Binding<NotificationPreferences>,
  scheduleName: String, scheduleNotes: String)` — sections `presetSection`,
  `svgIconSection` (bundled picker + custom `.fileImporter([.svg])`),
  `messageCustomizationSection` (Title `TextField` + message `TextEditor`; hint line
  "Available variables: {scheduleName}, {routineName}, {time}"), `positionSection`,
  `sizeSection`, `behaviorSection`, `previewSection`. The Preview button calls the
  private `showPreviewNotification()` which calls `showScheduleNotification(...)`.
  Also declares `extension UTType { static var svg }` (reused).
- `VibeNotifyConfig.showScheduleNotification(scheduleName:routineName:scheduledTime:
  notes:priority:preferences:)` (`Services/VibeNotifyConfiguration.swift`) — guards
  `NotificationPolicy.shared.isNotificationAllowed(priority:)`, formats title/message
  via `prefs.formatTitle/formatMessage`, then builds `VibeNotify.builder()`: SVG via
  `.svgURL(url,size:)` (http) or `.svg(path,size:)` (file) or fallback
  `.icon(.system("bell.badge.fill"))`; then `.title/.message/.moveable/.alwaysOnTop
  (true)/.dismissOnScreenTap(true)/.autoDismiss(after:)`, `.screenBlur(true,
  intensity:)` when enabled, `.position(...)` (switch over `NotificationPosition`),
  `.width/.height`, `.show()`. **This icon+builder block is what Task 3 extracts.**
- Current VibeCheck alert path (to be replaced): `showBFRBAlert(behavior:count:)`
  builds `OverlayWindowManager.Configuration` + `BFRBAlertView`; `BFRBAlertView`
  (`Views/VibeCheck/BFRBAlertView.swift`) renders `behavior.alertIcon`/`label`/`nudge`
  + streak. `VibeNotifyConfig.ordinal(_:)` builds the streak ordinal and is retained.
  The only caller is `VibeNotifyDetectionNotifier.notify` →
  `VibeNotifyConfig.showBFRBAlert(behavior:count:)` (keep this call working).
- `BFRBBehavior` (`Models/BFRB.swift`): `nailBiting/nosePicking/hairPulling`, with
  `label`, `alertIcon` (SF Symbol), `nudge` — the per-behavior defaults.
- `NotificationPriority` exists; the detection alert stays `.critical`.
- Persistence precedent: `DetectionPreference` — UserDefaults-backed, injectable
  `UserDefaults`, unit-tested with an ephemeral suite. Singleton precedent:
  `NotificationPolicy.shared`.
- Tests: swift-testing in `vibecareTests/` (auto-included). Run the **whole target**
  (granular `-only-testing:vibecareTests/Name` matches 0 tests): `xcodebuild test
  -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS'
  -only-testing:vibecareTests`. App builds via `just swift-build`.
- ⚠️ Case-insensitive FS: sources on disk at lowercase `.../vibecare/…`; git tracks
  the app group under capital `.../VibeCare/VibeCare/…`. Edit where files exist; `git
  add` and verify with `git status`.

## Design

### 1. Model — reuse `NotificationPreferences`
No new model. Per-behavior customization is one `NotificationPreferences` per
`BFRBBehavior`, seeded from `.default`. (Per-behavior full config; no separate
shared/override layer — each behavior is independently customizable, and the
Default/Minimal/Prominent presets provide the "shared" starting points.)

### 2. Persistence — `DetectionAlertPreferencesStore`
New `vibecare/Services/Detection/DetectionAlertPreferencesStore.swift`:
```swift
@MainActor
final class DetectionAlertPreferencesStore: ObservableObject {
    static let shared = DetectionAlertPreferencesStore()
    @Published var byBehavior: [String: NotificationPreferences]   // key = behavior.rawValue

    private let defaults: UserDefaults
    private let key = "vibecheck.alert.preferences"

    init(defaults: UserDefaults = .standard) { /* decode [String:NotificationPreferences] via try?, else [:] */ }

    /// Get-or-create the prefs for a behavior (seeded from `.default`), inserting so
    /// the editor binds a stable instance.
    func preferences(for b: BFRBBehavior) -> NotificationPreferences

    /// Encoded snapshot of the whole map — reading it touches every field of every
    /// `NotificationPreferences`, so a SwiftUI view using it as an `onChange` value
    /// re-evaluates on ANY field edit (Observation tracks the reads). This is how we
    /// get reliable auto-save despite `NotificationPreferences` being a reference type.
    var encodedSnapshot: Data { (try? JSONEncoder().encode(byBehavior)) ?? Data() }

    /// Persist the current map (called from the settings view's onChange).
    func persist()
}
```
`showBFRBAlert` reads `DetectionAlertPreferencesStore.shared.preferences(for:)`.

### 3. Renderer — extract a shared builder core
In `VibeNotifyConfiguration.swift`, extract from `showScheduleNotification` a private
generic:
```swift
@MainActor @discardableResult
private static func showNotification(
    preferences prefs: NotificationPreferences,
    title: String, message: String,
    defaultSystemIcon: String,
    priority: NotificationPriority
) -> UUID?
```
It does the `NotificationPolicy` guard, the SVG-vs-`.icon(.system(defaultSystemIcon))`
selection, and all builder customizations (position/size/moveable/blur/autoDismiss),
then `.show()`. Then:
- `showScheduleNotification` resolves title/message via `formatTitle/formatMessage`
  and calls `showNotification(…, defaultSystemIcon: "bell.badge.fill", priority: priority)`.
  Behavior is unchanged for schedules.
- New `showBFRBAlert(behavior:count:preferences:)`:
  ```swift
  @MainActor @discardableResult
  static func showBFRBAlert(
      behavior: BFRBBehavior, count: Int,
      preferences: NotificationPreferences = DetectionAlertPreferencesStore.shared.preferences(for: behavior)
  ) -> UUID? {
      let title = preferences.title?.nonEmpty ?? behavior.label
      let base  = preferences.message?.nonEmpty ?? behavior.nudge
      let message = "\(base)\n\(ordinal(count)) nudge today"
      return showNotification(preferences: preferences, title: title, message: message,
                              defaultSystemIcon: behavior.alertIcon, priority: .critical)
  }
  ```
  (`String.nonEmpty` — trims, nil if empty; add privately if not already available.)
- **Delete** `BFRBAlertView.swift` and remove the old `OverlayWindowManager`/
  `bfrbAlertDuration` path. `ordinal(_:)` stays.

### 4. UI — reuse `NotificationCustomizationView`, add per-behavior tabs
Generalize the editor with two optional params that default to current schedule
behavior (schedule callers unchanged):
```swift
NotificationCustomizationView(
    preferences: Binding<NotificationPreferences>,
    scheduleName: String, scheduleNotes: String,
    variablesHint: String? = nil,        // nil → existing "{scheduleName}, {routineName}, {time}" line
    onPreview: (() -> Void)? = nil        // nil → existing showPreviewNotification()
)
```
- `messageCustomizationSection` shows `variablesHint ?? "Available variables: …"`.
- `previewSection` button calls `onPreview ?? showPreviewNotification`.

New `vibecare/Views/VibeCheck/VibeCheckAlertSettingsView.swift`:
- `@StateObject private var store = DetectionAlertPreferencesStore.shared`, `@State
  private var selected: BFRBBehavior = .nailBiting`.
- A segmented `Picker` over `BFRBBehavior.allCases` (tabs).
- `NotificationCustomizationView(preferences: binding(for: selected), scheduleName:
  selected.label, scheduleNotes: selected.nudge, variablesHint: "Title/message default
  to this behavior's label & nudge. \"Nth nudge today\" is appended automatically.",
  onPreview: { VibeNotifyConfig.showBFRBAlert(behavior: selected, count: 1,
  preferences: store.preferences(for: selected)) })`.
  - `binding(for:)` returns `Binding<NotificationPreferences>` get = `store.preferences(for:b)`,
    set = assign into `store.byBehavior[b.rawValue]`.
- **Auto-save:** `.onChange(of: store.encodedSnapshot) { _, _ in store.persist() }` on
  the container (reliable via Observation field-tracking, per §2).
- Embedded in `VibeCheckControlsPanel` as a new `Section { DisclosureGroup("Advanced:
  Alert Appearance", isExpanded: $showAdvanced) { VibeCheckAlertSettingsView() } }`,
  collapsed by default.

## Testing (TDD for the pure/persistence pieces)

New `vibecareTests/DetectionAlertPreferencesStoreTests.swift`:
- `preferences(for:)` seeds from `.default` on first access and returns the SAME
  instance on repeat (stable binding).
- Persistence: with an ephemeral `UserDefaults(suiteName:)`, edit a behavior's prefs
  then `persist()`; a second store over the same suite reads the customized values
  back (proves UserDefaults-backed).
- Encoded snapshot decodes back to an equal map.

Renderer, editor generalization, `.fileImporter`, SVG, and Preview are verified by
`just swift-build` + xcodebuild build + manual run (Preview fires a real alert, no
camera). Existing `VibeCheckViewModelTests`/`DetectionPreferenceTests` and the
schedule flow must stay green; the old `DetectionAlertPreferencesTests.swift` is
removed with its model in Task 1.

## Non-goals

- No new notification model or renderer — reuse `NotificationPreferences`,
  `showScheduleNotification`'s builder core, and `NotificationCustomizationView`.
- No separate shared/override layer (per-behavior full config + presets instead).
- No change to schedule-notification behavior (editor generalization is
  default-preserving; renderer extraction is behavior-preserving).
- No per-behavior sound; alert stays `.critical`; detection geometry untouched.
