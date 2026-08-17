# VibeNotify Rich Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give VibeNotify one renderer that draws an illustration, buttons and a cancellable countdown, legible over any desktop, and retarget VibeCare's two consuming files at it.

**Architecture:** A third model + renderer (`RichNotification` / `RichNotificationView`) added beside the two existing ones, which do not change. One named `AlertMode` axis (`.interrupt` / `.ambient`) drives backdrop, chrome and legibility together. The dismiss clock moves out of the view bodies into `OverlayWindowManager`, keyed by id, injected via SwiftUI environment so caller-supplied content inherits it.

**Tech Stack:** Swift 6.1, SwiftUI, AppKit, SVGView 1.0.6, swift-testing. macOS 14 floor (library), macOS 15 (client).

**Spec:** `docs/superpowers/specs/2026-08-16-vibenotify-rich-renderer-design.md` — read it alongside this plan; every task argues from it.

## Global Constraints

- **Two repos.** Library: `/Users/thapakazi/repos/thapakazi/vibecare/simple-alerts` (Tasks 1–9). Client: `/Users/thapakazi/repos/thapakazi/vibecare/core` (Tasks 10–12).
- **Additive only.** No existing type gains/loses a property; no existing function signature changes; both existing renderers stay byte-identical.
- **`Configuration.init` (`OverlayWindowManager.swift:98-118`): new parameters MUST have defaults and MUST NOT be reordered or renamed.** `PluginInterrupt.swift:90-101` and `PluginAlertOverlay.swift:181-202` are memberwise literals that must keep compiling.
- **0.55** is the single derived constant: interrupt dim, ambient scrim peak alpha, and the "local scrim redundant" threshold. Derived once (spec §Where 0.55 comes from); never re-derive.
- Text is light in both modes, both themes: title white semibold, message white 0.9, footnote white 0.6. Shadows **oppose** text colour — title `.black.opacity(0.55)` r6 y1; message/footnote `.black.opacity(0.45)` r4 y1. Never `.clear`.
- **Decided this session:** interrupt takes keyboard focus. Under Reduce Transparency, ambient draws a solid opaque backdrop behind its text block (only for those users).
- Commit after every task. Library commits are bisectable; do not batch.
- To iterate on the library from the client before Task 10's release, run `swift package edit vibe-notify-macos --path ../../../../simple-alerts` from `clients/macos-swift/VibeCare/`. It is a per-developer, uncommitted override — **never commit a path dependency**, since SwiftPM derives identity from the directory basename (`simple-alerts`) and would break `package: "vibe-notify-macos"` at `Package.swift:56`.

---

### Task 1: Make the library's test target compile

**Files:** Modify `simple-alerts/Tests/VibeNotifyTests/VibeNotifyTests.swift:1`; modify `.github/workflows/release.yml:25-28`

- [ ] **Step 1:** Change `import TestingE` → `import Testing`. Replace the empty `example()` with a real assertion (`#expect(ScreenBlurIntensity.medium.radius == 25)`).
- [ ] **Step 2:** Run `swift test`. Expected: PASS. (Before this change it fails to compile with "no such module 'TestingE'".)
- [ ] **Step 3:** In `release.yml`, uncomment the test step and make it `swift test` without `|| true` and without `continue-on-error`. Add a `push`/`pull_request` trigger on branches so `main` is validated between releases.
- [ ] **Step 4:** Commit: `fix(tests): make the test target compile and gate releases on it`

### Task 2: Commit the pending glow fix on its own

**Files:** `simple-alerts/Sources/VibeNotify/Views/SVGNotificationView.swift:37` (already edited in the working tree)

- [ ] **Step 1:** Verify `git diff` shows only white→green on line 37. `changelog/30112025-adaptive-theme-support.md:16` already documents green, so shipped-white is the bug.
- [ ] **Step 2:** Commit that file alone: `fix(svg): apply the documented green glow in dark mode`

### Task 3: Fix blur-window orphaning (blocker for interrupt)

**Files:** Modify `simple-alerts/Sources/VibeNotify/Core/OverlayWindowManager.swift:190-214`; Test: `Tests/VibeNotifyTests/OverlayLifetimeTests.swift` (new)

Today `dismiss` returns at `guard let window = activeWindows[id]` (`:190-191`) **before** touching `blurWindows[id]`. At 0.1 dim that orphan is a nuisance; at 0.55 it is an inescapable dark sheet over the whole screen.

**Interfaces — Produces:** `dismiss(id:animated:)` tears down blur and main windows independently.

- [ ] **Step 1:** Write a failing test: show with `screenBlur: true`, remove the main window directly from `activeWindows`, call `dismiss(id:)`, assert `blurWindows[id] == nil`.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL (blur window survives).
- [ ] **Step 3:** Restructure `dismiss` so blur teardown is keyed on the id independently of the main-window guard. Add a sweep closing any `blurWindows` entry with no matching `activeWindows` entry.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `fix(overlay): never orphan a blur window`

### Task 4: `screenDim` parameter, `alwaysOnTop` as floor, Swift 6 warnings

**Files:** Modify `OverlayWindowManager.swift` — `Configuration` (`:77-139`), `createBlurWindow` (`:262-317`, dim pinned at `:289`), level logic (`:251`), `animateDismiss` (`:414-425`); Test: `Tests/VibeNotifyTests/ConfigurationTests.swift` (new)

**Interfaces — Produces:** `Configuration.screenDim: Double` (default `0.1`, clamped `0.1...0.95`), appended last in `init`.

- [ ] **Step 1:** Failing tests: default is `0.1`; `0.0` clamps to `0.1`; `2.0` clamps to `0.95`; `alwaysOnTop: true` with `windowLevel: .screenSaver` yields `.screenSaver`, not `.floating`.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Add `screenDim` **as the last init parameter with a default** (Global Constraints). Use it at `:289` in place of the hardcoded `0.1`. Change `:251` so `alwaysOnTop` takes the *higher* of `.floating` and the requested level rather than overriding it. Fix the two concurrency warnings at `:422-423` (capture the completion in a `@MainActor` context; do not call `NSWindow.close()` from a nonisolated sync context).
- [ ] **Step 4:** Run `swift test` and `swift build`. Expected: PASS, and the two warnings are gone.
- [ ] **Step 5:** Commit: `feat(overlay): make screen dim a parameter and window level a floor`

### Task 5: `AlertMode` + `Configuration` factories + public stored properties

**Files:** Create `Sources/VibeNotify/Models/AlertMode.swift`; modify `OverlayWindowManager.swift:78-96`; Test: extend `ConfigurationTests.swift`

**Interfaces — Produces:** `public enum AlertMode: Sendable { case interrupt, ambient }`; `Configuration.interrupt(...)` and `Configuration.ambient(...)`; `Configuration`'s stored properties readable.

- [ ] **Step 1:** Failing tests: `.interrupt` factory gives `presentationMode == .fullScreen`, `screenBlur == true`, `screenDim == 0.55`, `position == nil`, `alwaysOnTop == true`, and **takes key focus**; `.ambient` gives `screenBlur == false` and a non-nil position.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Add the enum and the two factories. Widen `Configuration`'s stored properties `internal` → `public` (they are all `let`, so no new mutability). Nothing else is widened.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(overlay): add AlertMode and configuration factories`

### Task 6: The countdown clock

**Files:** Create `Sources/VibeNotify/Core/NotificationClock.swift`; modify `OverlayWindowManager.swift` (`show` at `:148-187`, `dismiss` at `:190`); Test: `Tests/VibeNotifyTests/NotificationClockTests.swift` (new)

Spec §The clock. Three defects, one cause: a bare `asyncAfter` with no handle living inside the view body.

**Interfaces — Produces:**
```swift
@MainActor public final class NotificationClock: ObservableObject {
  public enum Phase: Sendable { case task, dismissing, finished, cancelled }
  public private(set) var phase: Phase
  public var deadline: Date { get }
  public var remaining: TimeInterval { get }
  public func completeTask()
  public func cancel()
}
```
`show(id:configuration:countdown:content:)` gains a `Countdown?` parameter; the manager stores `clocks[id]` and injects the clock into the SwiftUI environment around the hosting view at `:167-169`.

- [ ] **Step 1:** Failing tests: task phase then dismiss phase run **sequentially** (total = `duration + delay`, not `min`); `completeTask()` moves `.task` → `.dismissing`; `cancel()` moves to `.cancelled` and fires no completion; a deadline already in the past at wake yields `.cancelled`, never `.finished`; a stale generation token does **not** dismiss a recycled id.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement. `deadline` is a wall-clock `Date`, not a duration (sleep safety). Each clock carries a monotonically increasing generation; timer callbacks carry `(id, generation)` and no-op on mismatch. Subscribe to `NSWorkspace.didWakeNotification` to re-evaluate on wake. Cancel the clock **unconditionally at the top of `dismiss`, before** the `activeWindows` guard.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(overlay): own the countdown clock in the window manager`

### Task 7: `TaskTimer`, `DismissIndicator`, `AutoDismiss` shim

**Files:** Modify `Sources/VibeNotify/Models/NotificationContent.swift:127-135`; Test: extend `NotificationClockTests.swift`

**Interfaces — Produces:**
```swift
public struct TaskTimer: Sendable {
  public let duration: TimeInterval
  public let unitLabel: String        // "seconds"
  public let completionLabel: String  // "Break complete"
}
public enum DismissIndicator: Sendable { case none, bar, hairlineRing }
public struct Countdown: Sendable {          // the pair Task 6's show() takes
  public let task: TaskTimer?
  public let autoDismiss: AutoDismiss?
}
```
`AutoDismiss` gains `indicator: DismissIndicator`. `Countdown` is the single value `show(id:configuration:countdown:content:)` accepts; either half may be nil, and both nil means no clock. **Task 6 is written against this type — if the two tasks are done out of order, define `Countdown` first.**

- [ ] **Step 1:** Failing tests: `AutoDismiss(delay:showProgress: true)` maps to `.bar`; `false` maps to `.none`; both existing spellings still compile.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Add the types. Keep `init(delay:showProgress:)` (`:131`) and the builder's `autoDismiss(after:showProgress:)` (`API/VibeNotify.swift:467-470`) as `@available(*, deprecated)` shims — the library's own convenience constructors pass `showProgress: true` at `:243`, `:273`, `:288` and must keep compiling.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(models): split the countdown into task timer and dismiss indicator`

### Task 8: `RichNotification` + `RichNotificationView`

**Files:** Create `Sources/VibeNotify/Models/RichNotification.swift`, `Sources/VibeNotify/Views/RichNotificationView.swift`, `Sources/VibeNotify/Views/Scrim.swift`, `Sources/VibeNotify/Views/CountdownRing.swift`, `Sources/VibeNotify/Views/RichButtonStyle.swift`; Test: `Tests/VibeNotifyTests/LegibilityTests.swift` (new)

Model sketch: spec lines 177–194. `Illustration` carries its own size per case (`.svg(SVGSource, size:)`, `.image(NSImage, size:)`, `.symbol(String, pointSize:, color:)`).

**Interfaces — Consumes:** `AlertMode` (T5), `NotificationClock` (T6), `TaskTimer`/`DismissIndicator` (T7), `StandardNotification.Button` and `SVGSource` **reused verbatim**.

- [ ] **Step 1:** Failing tests on the pure decision function, not the view: `effectiveDim >= 0.55` → no local scrim; `< 0.55` including `0` → feathered scrim; Reduce Transparency + `.ambient` → solid backdrop; Reduce Transparency + `.interrupt` → opaque black at radius 0; a task timer suppresses the dismiss indicator.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement. Scrim = radial gradient black `0.55` → `0.0`, reaching **exactly zero inside** the drawn rect; `allowsHitTesting(false)`; behind the text block only. **Forbidden** (each turns it into a card): `RoundedRectangle`, `cornerRadius`, clip shape, `.regularMaterial`, `NSVisualEffectView`, stroke, shadow-on-scrim. Ring: arc is one `withAnimation(.linear(duration: remaining))` on `Shape.trim(to:)` set once per phase; the numeral is a `TimelineView(.periodic(from:by: 1))` scoped to the `Text` alone — not a `Timer` into `@State`, which would re-parse `SVGView` every second. Interrupt carries its own full-bleed transparent hit target (the blur window is occluded by a full-screen content window, so `dismissOnScreenTap` alone does not work). Buttons take taps before that target. Write `RichButtonStyle` chrome-less; do **not** reuse `Primary/Secondary/DestructiveButtonStyle` (`StandardNotificationView.swift:166-194`) — flat accent fills vanish against a blurred light desktop.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(rich): add the rich notification model and renderer`

### Task 9: Builder routing, deprecations, demo harness

**Files:** Modify `Sources/VibeNotify/API/VibeNotify.swift` (builder `:373-486`, `show()` `:489-562`, `showSVG` `:76`/`:133`); modify `Models/NotificationContent.swift:154`, `Views/SVGNotificationView.swift:5`; modify `VibeNotifyDemo/Sources/main.swift`; Test: `Tests/VibeNotifyTests/RoutingTests.swift` (new)

**Interfaces — Produces:** builder gains `.illustration(_:)`, `.footnote(_:)`, `.taskTimer(_:)`, `.mode(_:)`, all defaulted.

Routing rule, in order — rule 3 is why rule 1 exists:
1. Any rich-only field set (`mode`, `taskTimer`, `footnote`, `.image`/`.symbol` illustration) → rich renderer.
2. Else illustration present **and** `buttons` non-empty → rich renderer. *(the silent-drop bug fix)*
3. Else exactly 0.0.5 behaviour.

- [ ] **Step 1:** Failing tests: `.svg(...).button(...).show()` routes rich (today it silently discards buttons at `:490`); `.svg(...)` alone with no buttons still routes to the old renderer; `.mode(.interrupt)` routes rich even with no buttons.
- [ ] **Step 2:** Run `swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement routing. Add `@available(*, deprecated, message:)` naming `RichNotification` to both `showSVG` overloads, `SVGNotification` and `SVGNotificationView`. **Deprecate, do not assert** — `assertionFailure` compiles away in release and resumes the silent drop.
- [ ] **Step 4:** Add a demo case rendering each mode over a deliberately hostile backdrop, half-black/half-white split first. This is not a test; it is a repeatable way to look at the thing.
- [ ] **Step 5:** Run `swift test` and `swift build`. Expected: PASS.
- [ ] **Step 6:** Commit: `feat(api): route illustration+buttons to the rich renderer`

### Task 10: Release 0.0.6 and point core at it

**Files:** `simple-alerts` tag; modify `core/clients/macos-swift/VibeCare/Package.swift:32`, `Package.resolved:266-272`, `vibecare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:266-272`

- [ ] **Step 1:** Merge the library branch to `main`; confirm `swift test` is green on `main`.
- [ ] **Step 2:** Tag `0.0.6` and push the tag — the workflow triggers only on `*.*.*` tags, so pushing the tag *is* the release.
- [ ] **Step 3:** In core, bump `from: "0.0.5"` → `"0.0.6"` and re-resolve. **Both** resolved files move in the same commit (two build systems each keep their own; two disagreeing files is a failure this tree has had before).
- [ ] **Step 4:** `just swift-build`. Expected: builds clean with no client edits yet — proof the change is additive.
- [ ] **Step 5:** Commit: `build(client): take VibeNotify 0.0.6`

### Task 11: Retarget the schedule path

**Files:** Modify `core/clients/macos-swift/VibeCare/vibecare/Services/VibeNotifyConfiguration.swift:93-154` only

`showScheduleNotification` (`:48-84`) keeps its signature exactly. All change is inside the private `showNotification` funnel that every schedule alert and all three previews pass through.

- [ ] **Step 1:** Add `.mode(...)` to the builder chain at `:121-131`, derived from `prefs.screenBlurEnabled` (`:129`): blur on → `.interrupt`, blur off → `.ambient`. No new persisted key, no migration, no new UI control.
- [ ] **Step 2:** Map the `else` branch at `:118` (`.icon(.system(defaultSystemIcon))`, what an unconfigured schedule gets) to `Illustration.symbol`. Keep the SVG fork at `:107-119` in shape.
- [ ] **Step 3:** Leave the five generic helpers (`:164`, `:182`, `:200`, `:226`, `:254`) and `showToast`'s `IconType` leak untouched.
- [ ] **Step 4:** `just swift-test`. Expected: PASS, no test edits.
- [ ] **Step 5:** Verify with `just swift-run-app` (**not** `just swift-run` — see `Justfile:1097-1099`; only the Xcode build embeds the Info.plist). Split the desktop black-terminal-left / white-browser-right and fire a schedule notification. Title and message legible over **both** halves in **both** system appearances. Exercise all three preview buttons.
- [ ] **Step 6:** Commit: `feat(client): render schedule notifications through the rich renderer`

### Task 12: Retarget the plugin alert path

**Files:** Modify `core/clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginAlertOverlay.swift`

- [ ] **Step 1:** Delete `PluginAlertOverlayView` and `PluginAlertButtonStyle` (`:32-132`), the doc comment at `:8-24` (every item on its list is now false), the 15-argument `Configuration` literal (`:181-202`), and the `asyncAfter` at `:206-211`.
- [ ] **Step 2:** Keep `PluginAlertPresenter.show`'s six-parameter signature **byte for byte** — that freeze is what leaves `PluginShellService.deliver` (`:104`), its routing (`:156`), `PluginAlertPresentation.route` and `PluginAlertPresentationTests.swift:86-114` untouched. Body becomes: policy guard, builder chain, return id. Use `Illustration.image` — the icon arrives as an already-fetched `NSImage` and must stay that way (`PluginShellService.resolveIcon:207` fetches through core's proxy with a `vc_session` cookie; a URL would re-fetch unauthenticated and fail).
- [ ] **Step 3:** Keep `fittingHeight` (`:224-231`) and `windowPosition(for:)` (`:233-243`). The former survives because the `appearance` blob is out of scope for A; the latter is the insulation boundary.
- [ ] **Step 4:** `just swift-test`. Expected: PASS, zero test edits.
- [ ] **Step 5:** Verify in-app: a plugin alert renders at its existing geometry; ESC, click-anywhere and a button each dismiss an interrupt; a countdown cancelled by early dismissal does **not** fire afterwards; `PluginInterrupt`'s red flash still works (its 10-arg literal must still compile).
- [ ] **Step 6:** Commit: `refactor(client): drop the reimplemented plugin alert view`

### Task 13: Webview surface (added mid-run by user; do LAST)

**Not in the approved spec** — added by explicit user request during execution, to be done after Task 12. It overlaps sub-project C, which deferred "embedding the blink-jump game". Needs a short design pass before implementation; the notes below are what execution already knows, not a design.

**Goal:** VibeNotify can render a web page as an alert surface, in both `.interrupt` (full screen) and `.ambient` (popup) modes — e.g. the blink-jump plugin UI at `/p/blink-jump/`, so a 20-20-20 break can *be* the game.

**Known constraints — these are the hard part, not the WKWebView:**
- Plugin UIs are reverse-proxied by core at `<base_url>/p/<id>/` (`PluginList.base_url` in `proto/client/v1/client.proto`). The port is assigned at runtime, so no URL can be hardcoded.
- **Authenticated endpoints.** The client's existing `PluginWebView` appends `?vc=<token>` (`PluginList.token`) on the *first* load, and `PluginShellService.resolveIcon` fetches through the proxy with a `vc_session` cookie. A library-level `WKWebView` gets neither for free — it has its own `WKWebsiteDataStore` and cookie jar. Decide deliberately whether the library takes a pre-configured `WKWebView`/`WKWebViewConfiguration` from the caller (keeps all auth in VibeCare, keeps the library generic) or learns about tokens (couples a general-purpose library to VibeCare's auth). **Strong lean: the former** — VibeNotify is published for general use and must not learn what a `vc_session` is.
- The countdown clock and buttons must still work over the webview; the web content must not swallow ESC or the dismissal hit target.
- A live web page inside an interrupt is a focus and keyboard-input surface — revisit the "interrupt takes key focus" decision for this case specifically.

**Do not start this before Task 12 is complete and reviewed.**

---

## Deferred (do not build here)

Snooze rescheduling and driving the task timer from a schedule (B). The `appearance` blob and per-plugin mode control (C). Recording break outcomes anywhere. Restyling the banner/toast family. Removing the deprecated `showSVG`/`SVGNotification`/`SVGNotificationView` symbols (1.0).

## Open questions carried into implementation

- Completion beat length before a task-timer-only alert dismisses. Proposed 1.5s; user decides on seeing it run.
- Done-while-running dismisses immediately with an acknowledgement label ("Got it"), not `completionLabel` — a surface claiming a completed break when 18s were skipped is lying. User confirms on seeing it run.
- Exact CGS minimum background alpha (`OverlayWindowManager.swift:288` says "~0.1" with no measurement). Implementer re-measures on macOS 14 and 15 and adjusts the clamp floor.
- Whether Xcode honours `swift package edit` (`just swift-run-app` resolves via its own `XCRemoteSwiftPackageReference`). First developer to iterate answers it and records it in the library README.
