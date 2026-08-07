# VibeCheck Detection Notification — Design

> Design doc. Date: 2026-08-07. Branch: `feat/plugin-system`.
> Client-only feature (SwiftUI macOS app).

## Goal

When VibeCheck confirms a body-focused-repetitive-behavior (BFRB) detection —
nail-biting, nose-picking, or hair-pulling — show a **VibeNotify** center card
with a behavior-relevant icon and a warm, encouraging nudge, on top of the
existing interrupt sound and on-screen flash.

## Context

Detections are confirmed in `VibeCheckViewModel.fire(_:)`
(`ViewModels/VibeCheckViewModel.swift`). That path already runs only for events
that pass the detector's dwell + cooldown gating (`DetectionPolicy`), so it is
genuinely "a new detection" and is not spammy — no extra throttle is needed.
`fire` currently: increments `sessionCounts`, plays `interrupt`, reports to the
`plugin-vibecheck` plugin, and flashes the overlay.

VibeNotify is wired through `VibeNotifyConfig` (`Services/VibeNotifyConfiguration.swift`)
with a fluent builder supporting `.icon(.system(sfSymbol))`, `.position(.center)`,
`.screenBlur(true, intensity:)`, `.title/.message`, `.alwaysOnTop`,
`.dismissOnScreenTap`, `.autoDismiss(after:)`. All notifications funnel through
`NotificationPolicy.shared.isNotificationAllowed(priority:)`, and `.critical`
priority bypasses the global mute (bell) toggle.

## Decisions (from brainstorming)

- **Presentation:** **card-less** — the icon, bold title, and nudge float
  directly on a medium screen blur with **no card background**, matching the
  schedule (SVG) notification (`SVGNotificationView`). Centered, 64pt SF Symbol,
  spring-in animation, tap/ESC/auto-dismiss.
- **Copy:** bold title = the behavior label (no emoji — the icon conveys it),
  message = warm nudge + today's streak, e.g. `Nail-biting` /
  `Take a breath — hands down 💛` / `3rd nudge today`.
- **Policy:** always show — priority `.critical`, bypasses the bell toggle. The
  sound + flash already fire regardless.

### Why a custom view (not the standard builder)

`VibeNotify.builder().show()` routes non-SVG icons through
`StandardNotificationView`, which **always draws an opaque card** background
(`style.backgroundColor`). The card-less look is reserved for `SVGNotificationView`,
used only for SVG icons — and the icon catalog has no hand/nose/comb glyph. So the
alert is rendered as a custom `BFRBAlertView` (a plain `VStack`, no background) via
`OverlayWindowManager.shared.show(configuration:content:)`, whose window is
transparent. That lower-level path has no built-in auto-dismiss timer, so
`showBFRBAlert` schedules a `dismiss(id:)` after `bfrbAlertDuration` (6s).

## Components

### 1. Behavior → presentation mapping — `Models/BFRB.swift`

Extend `BFRBBehavior` with computed properties (single source of truth, pure,
unit-testable):

| behavior     | `alertIcon` (SF Symbol) | `nudge`                          |
|--------------|-------------------------|----------------------------------|
| nailBiting   | `hand.raised.fill`      | Take a breath — hands down 💛     |
| nosePicking  | `nose.fill`             | Ease off — hands away 💛          |
| hairPulling  | `comb.fill`             | Gently — hands down 💛            |

### 2. Notification helper — `VibeNotifyConfig.showBFRBAlert(behavior:count:)`

```swift
@MainActor @discardableResult
static func showBFRBAlert(behavior: BFRBBehavior, count: Int) -> UUID?
```

- Guard `NotificationPolicy.shared.isNotificationAllowed(priority: .critical)`
  (the one policy chokepoint; always true here → always shows).
- Render a card-less `BFRBAlertView` (icon + `behavior.label` + `nudge` +
  `ordinal(count)` streak, no background) via
  `OverlayWindowManager.shared.show(id:configuration:content:)` with a
  `Configuration` of `position: .center`, `width: 480`, `height: 300`,
  `screenBlur: true`, `screenBlurIntensity: .medium`, `dismissOnScreenTap: true`,
  `alwaysOnTop: true`, `isMoveable: true`.
- Schedule auto-dismiss: a `Task` sleeps `bfrbAlertDuration` (6s) then calls
  `dismiss(id:)`. The view also dismisses on tap; ESC works via the manager.
- Private `ordinal(_ n: Int) -> String`: 1→"1st", 2→"2nd", 3→"3rd", 4→"4th",
  11→"11th", 12→"12th", 13→"13th", 21→"21st" (standard English ordinal rules).

### 3. Wire into `VibeCheckViewModel`

Mirror the existing injectable `interrupt` seam with a notifier so the behavior
is testable without touching real windows:

```swift
protocol DetectionNotifying { @MainActor func notify(behavior: BFRBBehavior, count: Int) }

struct VibeNotifyDetectionNotifier: DetectionNotifying {
    @MainActor func notify(behavior: BFRBBehavior, count: Int) {
        VibeNotifyConfig.showBFRBAlert(behavior: behavior, count: count)
    }
}
```

- Add `private let notifier: DetectionNotifying`, injected in `init` with a
  default of `VibeNotifyDetectionNotifier()`.
- In `fire(_:)`, right after `sessionCounts[event.behavior, default: 0] += 1`,
  call `notifier.notify(behavior: event.behavior,
  count: sessionCounts[event.behavior, default: 0])`. Sound, plugin report, and
  flash are unchanged.

## Testing (TDD)

- **Model mapping** (`BFRBBehaviorTests`): every case returns a non-empty
  `alertIcon` and `nudge`; icons are the expected SF Symbols.
- **Ordinal helper**: 1,2,3,4,11,12,13,21,22,23,100,101,111 → correct suffixes.
  (Expose `ordinal` at internal visibility, or test it via a thin wrapper.)
- **View model** (`VibeCheckViewModelTests`): a confirmed detection invokes the
  injected notifier exactly once with the matching behavior and the
  post-increment count. Use a spy `DetectionNotifying`.

## Non-goals

- No change to detection geometry, sensitivity, dwell, or cooldown.
- No new image assets — SF Symbols only.
- No change to the plugin or its stored stats.
- Localization of the copy is out of scope (English strings inline).
