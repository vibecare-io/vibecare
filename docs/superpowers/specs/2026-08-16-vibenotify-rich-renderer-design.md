# VibeNotify rich renderer — design

**Status:** draft for review.
**Scope:** sub-project A of three. B puts a time offset on the `schedule_actions` join table so one rrule can express T-60s / T / T+20s, and will drive the task timer this spec builds. C builds a full-screen break window hosting the blink-jump plugin and extends the `appearance` blob to describe it. Neither is designed here.

## Decisions

| Decision | Reason |
| --- | --- |
| Two alert modes, `.interrupt` and `.ambient`, as one named axis above the existing geometry enum | Geometry, backdrop, chrome, escape routes, countdown role and legibility are only ever correct together; today every caller rediscovers the combination by hand |
| Never a card or panel | The user rejected it; reference image 2 is chrome-less content floating on a dimmed desktop |
| Text colour derives from the scrim we drew, never from `colorScheme` | The backdrop is the user's live desktop; the system theme answers a question about the OS, not about the pixels underneath |
| Screen dim becomes a `Configuration` parameter, default `0.1`, `.interrupt` uses `0.55` | The pinned `0.1` is a CoreGraphics requirement, not a design value; `0.55` is the smallest dim at which white text clears 4.5:1 over *any* desktop |
| Shadows oppose the text colour; never `.clear`, never the text's own colour | Today light mode gets no shadow and dark mode gets a white halo under white text |
| A third renderer, `RichNotificationView`, added beside the two existing ones | Retrofitting either means rewriting its body and then flagging the old behaviour back in — two renderers wearing one name |
| The countdown splits into a task timer and a dismiss indicator | One draining `ProgressView` is being asked to mean both "look away for 20 more seconds" and "this closes soon" |
| The clock moves out of the view bodies into `OverlayWindowManager` | So it is cancellable, written once, and inherited by caller-supplied content |
| Ships as VibeNotify **0.0.6** | Everything is additive; pre-1.0 carries no stability promise a bigger bump would honour |
| Packaging stays a remote `from:` dependency; developers use `swift package edit` | A path dependency's SwiftPM identity is the directory basename, which would break `package: "vibe-notify-macos"` at `Package.swift:56` |
| The schedule path derives its mode from `prefs.screenBlurEnabled` | That toggle is already the user's way of saying "take over my screen"; no new persisted key, no migration, no new control |
| No streaks, no history, no persistence of break outcomes | The user reviewed the reference image's stats bar and streak row and declined both |

## Problem

A 20-20-20 eye-break notification renders an eye illustration, a title and a message floating over the blurred desktop. On a split desktop — black terminal left, white browser right — the title and message land over the black half and vanish. The illustration survives because it carries its own glow; the words do not.

The cause is that `SVGNotificationView` derives text colour from the system appearance and from nothing else. `useLightText` is defined as `colorScheme == .dark` (`Sources/VibeNotify/Views/SVGNotificationView.swift:17-20`) and every colour decision branches on that one boolean. In light mode the title draws `.primary` with a shadow that is literally `.clear` (`:46-47`), so dark text sits on whatever is behind it with zero separation. In dark mode it draws white text under a *white* glow (`:47`, `:56`) — a halo, which reinforces the text against dark backdrops and erases it against light ones.

Legibility is a property of the backdrop, and the backdrop is the user's live desktop, which the notification does not own and cannot predict. On a split screen there is no theme-derived colour that works on both halves.

Screen blur cannot rescue it, and it is worth being precise because "blur harder" is the obvious first idea: **a blur preserves local mean luminance.** Blurring a white browser half yields a white half. Radius destroys detail, not light. On top of that, the blur window's dim is pinned at `NSColor.black.withAlphaComponent(0.1)` for every intensity (`Sources/VibeNotify/Core/OverlayWindowManager.swift:289`), with the comment above it recording why: "Window needs sufficient background alpha for blur to be visible (~0.1 minimum)". `ScreenBlurIntensity` changes radius only — 10 / 25 / 50 / clamped (`Models/ScreenBlurIntensity.swift:15-22`).

The hook for the fix was scaffolded and never implemented: `SVGNotificationView` accepts `screenBlurActive` at `:8`, `API/VibeNotify.swift:322-323` faithfully threads `configuration.screenBlur` into it, and the body never reads it.

Fixing legibility alone would not reach the break experience the reference images describe. Three further gaps block it, each in a different layer.

**An illustration and buttons cannot coexist.** `SVGNotification` has no `buttons` property (`Sources/VibeNotify/Models/NotificationContent.swift:154-176`); only `StandardNotification` does (`:14`), and its renderer maps `IconType.svg` and `.url` to `EmptyView()` (`Sources/VibeNotify/Views/StandardNotificationView.swift:104-107`) and pins `IconType.image` to a hardcoded 48×48 (`:103`). Worse, the builder's `show()` forks on `useSVG` (`API/VibeNotify.swift:489-562`, fork at `:490`) and routes to `showSVG(...)`, whose parameter list has no `buttons:` — so `.svg(...).button(...).show()` compiles and silently discards every button, with no assert, warning or diagnostic.

**There is no countdown of any kind.** `AutoDismiss` carries exactly `delay` and `showProgress` (`NotificationContent.swift:127-135`), and `showProgress: true` renders an unlabelled draining linear `ProgressView` — no number, no ring, no remaining-seconds text (`SVGNotificationView.swift:61-65`, duplicated byte-identically at `StandardNotificationView.swift:50-54`).

**Caller-supplied SwiftUI content gets no timer at all.** Both the bar and the dismiss timer live inside the two renderer bodies (`SVGNotificationView.swift:94-106`, `StandardNotificationView.swift:149-161`), not in the window manager, and the timer is a bare `DispatchQueue.main.asyncAfter` with no cancellation handle — so a button tap or ESC does not stop it.

The client has already paid for all of this in duplicated code. `PluginAlertOverlayView` plus its private button style (`clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginAlertOverlay.swift:32-132`) is a reimplementation of `SVGNotificationView` with a button row, and its doc comment (`:8-24`) is an explicit inventory of what VibeNotify 0.0.5 cannot do. The presenter schedules its own `asyncAfter` (`:209-211`) precisely because caller-supplied views get none. That is the real cost: two divergent break-notification implementations, and only the wrong one is reachable from the schedule path.

## Scope

**In:** the library changes below; retargeting the client files that import VibeNotify; the countdown engine; the dim parameter; the legibility rules; the Done/Snooze/Skip row, completion confirmation and live progress; the test strategy; the `swift package edit` setup; the release path.

**Out:** any change to the `appearance` JSON blob — a hand-maintained cross-language contract spanning `core/sdk/swift/VCPluginSDK/Sources/VCPluginSDK/VCAlertAppearance.swift`, `core/plugins/vibecheck/Sources/VibeCheckKit/AlertPrefsStore.swift` and three byte-exact JSON test literals; any change to `schedule_actions`, the proto, the scheduler or the CLI `--json` contract; streaks, history, or persistence of break outcomes; embedding the blink-jump game.

One renderer must serve both paths. The schedule path (`Services/NotificationManager.swift:41` → `Services/VibeNotifyConfiguration.swift:48`) and the plugin path (`Services/PluginShellService.swift:104`, routed at `:156`) reach two different views today, which is why a schedule notification cannot have buttons and a plugin alert cannot be triggered by an rrule. Retiring `PluginAlertOverlayView` in favour of a library renderer is the concrete success test.

## Alert modes

VibeNotify 0.0.5 has geometry but no presentation *intent*. `OverlayWindowManager.PresentationMode` (`OverlayWindowManager.swift:61-74`) says only where a rectangle lands, and eighteen independent `Configuration` knobs (`:78-96`) must each be set consistently by hand. The client demonstrates the cost twice: `PluginAlertOverlay.swift:181-202` and `PluginInterrupt.swift:90-101` are fifteen- and ten-argument memberwise literals that had to rediscover the same combination of `isTransparent`, `alwaysOnTop`, `backgroundColor: .clear` and "no window material" to get a chrome-less float.

This spec adds one named axis above that machinery.

```swift
public enum AlertMode: Sendable {
  case interrupt   // whole screen becomes the scrim
  case ambient     // positioned window, desktop untouched
}
```

It is deliberately not called `PresentationMode`; that name is taken by the geometry enum and the two must stay distinguishable in call sites and diffs. A caller picks a mode and supplies content; it does not set `screenBlur`, `screenDim`, `dismissOnScreenTap`, `windowLevel` or text colours independently. `OverlayWindowManager.show(id:configuration:content:)` (`:148-187`) stays public and unchanged for callers that want the old freedom.

### Scrim is not card

The user asked for a scrim behind the text and rejected the card view. That is a contradiction only if the two words name the same object.

A **card** is bounded: an edge, a corner radius, a fill uniform right up to that edge, usually a drop shadow announcing it as a sheet stacked on the desktop. It declares *this is a separate object in front of your work*. That is image 1, and that is what was rejected.

A **scrim** is unbounded: a luminance gradient with no edge to perceive. It declares nothing; it only says *less light gets through here*. Image 2 is a screen-sized scrim.

The two modes are the same principle at two radii of application. In `.interrupt` the whole screen is the scrim, so there is nothing left to put a local scrim on — a local one there would be a visible rectangle over a uniform field, which is a card arrived at by accident. In `.ambient` a screen-sized scrim is forbidden (dimming the desktop for a toast is a category error), so the scrim is local, and to stay a scrim rather than becoming a card it must feather to zero before its geometry ends.

### `.interrupt`

Used when the alert *is* the task: a scheduled break, a full-attention prompt. Sub-project B's T-0 stage will fire in this mode.

*Geometry.* `.fullScreen` on the target screen, content centred, `position`/`width`/`height` left nil. An explicit position and size override the presentation mode entirely (`createWindow`, `:224-259`, position override at `:236-239`) — that override is what `PluginAlertPresenter` relies on, and interrupt mode must not use it.

*Backdrop.* One blur window per alert id as today (`createBlurWindow`, `:262-317`), with a heavy radius and a dim of 0.55.

*Chrome.* None. `backgroundColor: .clear`, `isTransparent: true`, no `transparentMaterial`, no rounded rectangle, no border, no container shadow because there is no container. Illustration, title, message, ring, button row and footnote sit directly on the scrim in one centred vertical stack.

*Escape.* Three routes, live simultaneously: ESC, a click anywhere, and explicit buttons. ESC already works — `DismissibleWindow.keyDown` traps keyCode 53 (`:8-15`) and `show` wires `onEscapePressed` (`:171-174`).

Click-anywhere does **not** work today in this configuration, and that is a defect to fix rather than inherit. `dismissOnScreenTap` installs its handler on the *blur* window (`:280`, `:293-300`), which is levelled one step below the notification window (`:276-279`). With a content window sized to the alert, clicks outside it fall through and dismiss; with a full-screen content window the blur window is completely occluded and receives nothing. Interrupt mode therefore carries its own full-bleed transparent hit target inside the content view. `dismissOnScreenTap` stays set on the blur window so the two paths agree.

### `.ambient`

Used when the alert is peripheral: confirmations, warnings, plugin notices, toasts. This is what the six builder call sites in `VibeNotifyConfiguration.swift` (`:48`, `:164`, `:182`, `:200`, `:226`, `:254`) map onto.

*Geometry.* A positioned window sized to its content — the shape `PluginAlertPresenter` already produces by hand (`PluginAlertOverlay.swift:181-190`).

*Backdrop.* No blur window at all. `screenBlur: false`; dim does not apply. The desktop keeps its light and every other window stays clickable.

*Chrome.* Still none. The text block alone gets the feathered scrim.

*Escape.* "Click anywhere" is unavailable by construction — there is no global surface, and stealing desktop clicks for a toast is worse than the problem it solves. Ambient dismisses on a click on the alert itself, on ESC while its window is key, on its buttons, and on auto-dismiss expiry.

## Legibility

### The invariant

> Text is never rendered over a backdrop whose luminance we do not control.

Interrupt satisfies it by dimming the entire screen; ambient by placing a local feathered scrim under the text block. Text colour then follows the scrim we drew. `useLightText` and its `@Environment(\.colorScheme)` dependency (`SVGNotificationView.swift:10`, `:17-20`) are deleted outright, as is the clone at `PluginAlertOverlay.swift:48`.

Because both scrims are dark, both modes render light text in both system themes: title pure white semibold; message white at 0.9; footnote white at 0.6. The illustration gets a dark drop shadow, not a glow — `SVGNotificationView.swift:37` currently applies `.green.opacity(0.5)` in dark mode, which is a halo for the same reason the title's is.

### Where 0.55 comes from

Worst case for light text is a pure white desktop. Compositing black at alpha *a* over white leaves sRGB `1 − a`; for white text to clear WCAG AA at 4.5:1 the backdrop's relative luminance must be at most `1.05/4.5 − 0.05 = 0.1833`, which is sRGB ≈ 0.465, i.e. *a* ≈ 0.535. Rounded up, **0.55 is the smallest dim at which white text is guaranteed legible over any desktop whatsoever.** That single number is used three times and derived once: it is the interrupt dim, it is the ambient scrim's peak opacity, and it is the threshold above which a local scrim is redundant.

### Shadows oppose the text

Every text element carries a shadow whose colour is the opposite pole from the text's own. Light text gets a dark shadow; dark text, should any path produce it, gets a light one. Never `.clear`, never the text's own colour.

For the light text above: title `.black.opacity(0.55)`, radius 6, offset y 1; message and footnote `.black.opacity(0.45)`, radius 4, offset y 1. A small positive y offset rather than a symmetric halo — a displaced shadow reads as separation, a centred one reads as glow.

Under the invariant the shadow is a second-order safety net, not the contrast mechanism: it covers the seam where a glyph's antialiased edge meets an unusually bright patch surviving the scrim. It is written as a general opposition rule so it stays correct under any future inversion, and so `StandardNotificationView` — which supplies its own opaque card (`:68-76`) and therefore already controls its backdrop — can adopt it without a special case.

### The feathered scrim (ambient only)

A radial gradient, black, from 0.55 at the centre of the text block to 0.0 at the edge of a rect padded outward well past the text bounds — far enough that the falloff completes before the geometry ends. Nothing else. Explicitly absent, because each of these is what turns it back into a card: no `RoundedRectangle`, no `cornerRadius`, no clip shape; no `.background(.regularMaterial)` or `NSVisualEffectView`; no stroke or hairline; no shadow on the scrim itself.

It is `allowsHitTesting(false)`, and it sits behind the text block only — not behind the illustration, not behind the buttons, which carry their own contrast. For wide, short blocks a vertical linear gradient with the same endpoints is permitted; the constraint is that alpha reaches exactly zero inside the drawn rect, never at its boundary.

### `screenBlurActive` becomes the selector, carrying dim

The stubbed parameter at `SVGNotificationView.swift:8` is the natural place to select between the two strategies — the renderer needs to know whether something else already made the backdrop safe. It cannot stay a boolean over `screenBlur`, because `screenBlur == true` is also true for a `.light` blur at the pinned 0.1, which is not a safe backdrop. The bit that matters is the dim. So the renderer's input becomes the effective backdrop dim:

- dim ≥ 0.55 → a global scrim already exists → draw no local scrim.
- dim < 0.55, including 0 → draw the feathered scrim.

`init(notification:screenBlurActive:onDismiss:)` (`:22-30`) is retained as a shim mapping `true → 0.1` and `false → 0`, so existing call sites compile and — correctly — now get the feathered scrim they should always have had.

### The dim parameter

Add `screenDim: Double` to `Configuration`, **defaulting to 0.1**. That default reproduces today's rendering byte for byte, so all six adapter call sites and both hand-written literals in the client are unaffected by the addition alone. `.interrupt` sets 0.55. `.ambient` builds no blur window, so the value is inert.

Clamp to `0.1...0.95`. The floor is not 0: with blur enabled, an alpha below the CGS minimum silently stops the blur compositing, so "blur with no dim" is not expressible and a caller who wants an undimmed desktop must turn blur off instead. The ceiling is not 1.0: a fully opaque backdrop is no longer a blur.

**Dim and radius are independent axes and stay independent.** Radius controls how much of the desktop's *detail* survives; dim controls how much of its *light* survives. Heavy blur with no dim is a legitimate privacy screening; light blur with a heavy dim is a legible interrupt that still shows you roughly where your windows are. Folding dim into `ScreenBlurIntensity` would make both inexpressible.

### Accessibility

`PluginInterrupt.swift:75` gates its red flash on `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, and it is the only such check in either repository. Both new modes follow that precedent.

*Reduce Motion.* `animatePresentation` goes false, so the window is ordered front at final opacity; the spring entrance (`SVGNotificationView.swift:77`, mirrored at `PluginAlertOverlay.swift:107`) is skipped and content appears at final scale. Ambient additionally drops any slide-in.

The countdown is the deliberate exception: it keeps animating, because it is information the user is reading, not decoration. What changes is cadence — arc and numeral advance in discrete one-second steps instead of a continuous sweep. The existing `withAnimation(.linear(duration: delay))` at `:97` has no step mode and no cancellation handle, which is one more reason the countdown is rebuilt rather than parameterised.

*Reduce Transparency* (`accessibilityDisplayShouldReduceTransparency`, checked nowhere today). Interrupt replaces blur-plus-dim with a solid opaque black backdrop at radius 0; the desktop was already unreadable behind a 0.55 dim and a 50-point blur, so honouring the setting costs nothing.

Ambient is harder, and is an open question below: a feathered scrim *is* a transparency gradient and cannot be made opaque and stay edgeless.

## The rich model and renderer

A third path — `RichNotification` plus `RichNotificationView` — is added alongside `StandardNotificationView` (`StandardNotificationView.swift:4`) and `SVGNotificationView` (`SVGNotificationView.swift:5`). Neither existing renderer changes. Neither existing model changes.

### Why a third renderer and not a retrofit

Retrofitting `SVGNotificationView` means adding buttons, style and an icon concept to `SVGNotification`, which has none of them (`NotificationContent.swift:154-176`: six stored properties). It means adding `buttons:` to both `showSVG` overloads (`API/VibeNotify.swift:76-97`, `:133-154`), each already twenty parameters wide, and threading it through `showSVGNotification` (`:314-331`). And it means rewriting the body anyway: the only button it can draw is a hardcoded `"Dismiss"` behind `interactive == true` (`SVGNotificationView.swift:68-73`), and the legibility rules replace its colour logic wholesale. Nothing of the original would survive but the `SVGView` call — yet every existing caller still depends on the old rendering, so the old behaviour must be preserved behind a flag. A renderer with a "behave like 0.0.5" flag is two renderers wearing one name.

Retrofitting `StandardNotificationView` is worse, because its limitations are load-bearing for the shape it draws: `EmptyView()` for SVG and URL icons (`:104-107`), a hardcoded 48×48 image frame (`:103`), a 48pt font for symbols (`:29`), and an unconditional opaque card (`:68-76`). Undoing the first three means giving `IconType` a size, which changes a public enum every existing caller constructs, including `NotificationManager.swift:92`.

The third renderer touches nothing that ships today. If it is wrong, it is deleted.

### The model

A sketch, not an implementation:

```swift
public struct RichNotification {
    public enum Illustration {
        case svg(SVGSource, size: CGSize)
        case image(NSImage, size: CGSize)
        case symbol(String, pointSize: CGFloat, color: Color?)
    }

    public let illustration: Illustration?
    public let title: String?
    public let message: String?
    public let footnote: String?               // "Press ESC or click anywhere to skip"
    public let buttons: [StandardNotification.Button]
    public let taskTimer: TaskTimer?
    public let autoDismiss: StandardNotification.AutoDismiss?
    public let mode: AlertMode
}
```

Size lives inside each `Illustration` case rather than as a sibling property because an SF Symbol is sized by a point size and a bitmap or SVG by a `CGSize`; one shared `CGSize` would force callers to encode a font size as a square rectangle. This is also the field that makes the illustration arbitrary — the fixed 48×48 is the defect being escaped, and image 2's eye glyph is nothing like 48pt. All three cases have a named consumer: `.image` for `PluginAlertPresenter`, which is handed an already-fetched `NSImage`; `.symbol` for the schedule path's no-SVG fallback at `VibeNotifyConfiguration.swift:118`; `.svg` for everything else.

`footnote` is a fifth text slot and exists only because image 2 has one: the small line pinned below the ring. It is separate from `message` because it styles differently and because in `.ambient` it is usually absent.

`mode` sits on the model, not only on the window `Configuration`, because the renderer must read it to choose between the two legibility strategies. The presenter derives the `Configuration` from the mode so the two cannot disagree.

### What is reused verbatim

`StandardNotification.Button` (`NotificationContent.swift:69-86`) is used unchanged: already public, already `Identifiable` via `let id = UUID()`, and already carrying the three-case `ButtonStyle` a Done / Snooze / Skip row needs. Inventing a parallel type would fork the type the client's own `NotificationAction` (`NotificationManager.swift:10-13`) bridges to.

`SVGSource` (`:139-151`) already covers file paths and remote URLs, so `Illustration.svg` takes it directly.

`OverlayWindowManager.show(id:configuration:content:)` (`:148-187`) and `dismiss(id:animated:)` (`:190-214`) are already public and sufficient — the client proves it (`PluginAlertOverlay.swift:204`). The rich path is one more caller.

Deliberately *not* reused: `PrimaryButtonStyle`, `SecondaryButtonStyle` and `DestructiveButtonStyle` (`StandardNotificationView.swift:166-194`). They are card chrome — a flat accent fill that vanishes against a blurred light desktop. The client hit exactly this and wrote its own material-backed style with a comment saying so (`PluginAlertOverlay.swift:117-132`). The rich renderer needs its own chrome-less button style, in the library, and shipping it is what lets that private style be deleted.

### One access widening

`Configuration`'s stored properties (`OverlayWindowManager.swift:78-96`) go `internal` → `public`. They are currently write-only from outside the module: the public init (`:98-118`) lets a caller build one and nothing lets a caller read one back. That is exactly why the client hand-writes two full literals instead of taking a base and adjusting one field. Public reads, plus named factory helpers (`Configuration.interrupt(...)`, `Configuration.ambient(...)`), are the precondition for replacing both literals with derive-and-adjust. All the properties are `let`, so no new mutability is exposed; the cost is semver surface, accepted because the client already depends on these names positionally.

No other member is widened. Every other candidate considered had no named caller in this work.

### Builder routing, and the silent button drop

The builder gains `.illustration(_:)` (with `.svg`/`.svgURL` kept as-is), `.footnote(_:)`, `.taskTimer(…)` and `.mode(_:)`, all additive with defaults.

The important change is in `show()` (`API/VibeNotify.swift:489-562`). The routing rule, in order:

1. If any rich-only field is set — `mode`, `taskTimer`, `footnote`, or an `.image`/`.symbol` illustration — route to the rich renderer.
2. Otherwise, if an illustration is present **and** `buttons` is non-empty, route to the rich renderer. This is the bug fix: `self.buttons` (`:348`, populated by `.button(_:)` at `:388-391`) is honoured instead of dropped.
3. Otherwise, behave exactly as 0.0.5 does.

Rule 3 is why rule 1 exists. The bug that started this arrives through `VibeNotifyConfiguration.showNotification` (`:93-154`), which sets `.svg(...)` or `.svgURL(...)` (`:110`, `:115`) and never calls `.button(...)`. Under rule 2 alone that call would stay on the old renderer and stay broken. The client fixes it by adding one `.mode(...)` call — a deliberate opt-in, so third-party callers asking for an SVG and nothing else keep the pixels they have today.

On the old path: **deprecate, do not assert.** Add `@available(*, deprecated, message:)` to both `showSVG` overloads (`:76`, `:133`), to `SVGNotification` (`NotificationContent.swift:154`) and to `SVGNotificationView` (`:5`), naming `RichNotification` as the replacement, in the same release. An `assertionFailure` fires at show time on a user's machine and compiles away in release builds, resuming the silent drop. More decisively, after rule 2 there is nothing left to assert on: direct callers of `showSVG` cannot lose buttons because the signature has no `buttons:` parameter, and `SVGNotification` cannot carry buttons because it has no such property. Removal of the deprecated symbols is a 1.0 concern.

### Compatibility

Additive. New type, new view, new builder methods defaulting to 0.0.5 behaviour, one access widening, and one new `Configuration` field whose default reproduces today's 10% dim. No existing type gains or loses a property; no existing function signature changes; both existing renderers are byte-identical. Every current call site in this tree keeps compiling and rendering what it renders now.

The one behavioural change is `.svg(...).button(...).show()`, which stops producing a buttonless notification. That is a bug fix, and it has zero call sites in this repository.

## Countdown

Today's single draining bar is asked to mean two things at once, which is why it means neither. A countdown that measures *the exercise* and one that measures *how long this window stays up* are not the same clock, do not have the same visual weight, and do not end the same way.

### Two types

**`TaskTimer`** is the large tick-marked ring from image 2: a numeric seconds count, a unit label under it, a draining arc. It counts what the user was asked to do, and after the illustration it is the largest element on the surface.

```swift
public struct TaskTimer: Sendable {
    public let duration: TimeInterval
    public let unitLabel: String          // "seconds" — the caller's word
    public let completionLabel: String    // shown at zero, e.g. "Break complete"
}
```

**`DismissIndicator`** is the generic "this closes in N". No number, no label; a thin draining bar or a hairline ring at the edge of the content, deliberately quiet, because nobody needs to watch a toast expire — they need to be able to tell that it will. It replaces the `showProgress: Bool` flag:

```swift
public enum DismissIndicator: Sendable { case none, bar, hairlineRing }
public struct AutoDismiss {
    public let delay: TimeInterval
    public let indicator: DismissIndicator
}
```

`init(delay:showProgress:)` (`NotificationContent.swift:131`) and the builder's `autoDismiss(after:showProgress:)` (`API/VibeNotify.swift:467-470`) stay as deprecated shims mapping `true → .bar`, `false → .none`. The library's own convenience constructors pass `showProgress: true` unconditionally (`:243`, `:273`, `:288`), as do five of the six client call sites; all of them keep compiling.

A task timer renders when and only when the alert declares one — never inferred from `autoDismiss`. A dismiss indicator renders when auto-dismiss is configured with a non-`.none` indicator *and* no task timer is running. Two clocks counting on the same surface is the failure this split exists to prevent.

`.ambient` gets the dismiss indicator only. A labelled ring reads as a task, and in ambient mode there is no task — the number would answer a question the user did not ask.

### When both are set

`.taskTimer(20)` and `.autoDismiss(after: 5)` are not a conflict to arbitrate. They are two sequential phases: **the task timer runs first and alone; the auto-dismiss clock is armed the moment the task reaches zero, and its delay is measured from that moment.** Total on-screen time is `duration + delay`, bounded and predictable. During the task phase no dismiss indicator is drawn.

Earliest-deadline-wins was considered and rejected: it lets the shorter number silently destroy the longer one, so a caller who set a 5-second ceiling out of habit would kill a 20-second eye break at second five and never learn why.

When a task timer is present and no auto-dismiss is set, reaching zero dismisses the alert after holding the completion state for a short beat.

### The clock

Three defects share one cause: the timer is a bare `asyncAfter` with no cancellation handle living inside the view body, so it cannot be stopped from outside, it had to be written twice, and caller-supplied content gets none.

Move it into `OverlayWindowManager`, beside the two dictionaries it already keeps. The manager is already the right owner: it creates the window, owns the ESC handler (`:172`) and the tap-to-dismiss wiring (`:280`, `:296`, `:308`), and holds `activeWindows[id]` and `blurWindows[id]`. A clock is one more thing keyed by the same id.

```swift
@MainActor public final class NotificationClock: ObservableObject {
    public enum Phase: Sendable { case task, dismissing, finished, cancelled }
    public private(set) var phase: Phase
    public var deadline: Date { get }        // wall clock, not a duration
    public var remaining: TimeInterval { get }
    public func completeTask()               // "Done" — end the task phase now
    public func cancel()                     // Skip / ESC / click-away
}
```

`show(id:configuration:countdown:content:)` gains a `Countdown?` parameter. The manager builds the clock, stores it in `clocks[id]`, and injects it into the SwiftUI environment around the hosting view at `:167-169`. That injection is the whole point: the built-in renderers read it from the environment, and so does any caller-supplied content — which is how the fourth problem disappears without those callers asking for anything.

**Cancellation is the window's job, not the view's.** Every dismissal path already funnels into `dismiss(id:animated:)`: buttons call `onDismiss()`, which for built-in notifications is `VibeNotify.dismiss(id:)` (`API/VibeNotify.swift:305`, `:326`); ESC calls it directly (`OverlayWindowManager.swift:173`); a screen tap calls it (`:298`). Cancelling the clock inside `dismiss` fixes button-tap and ESC cancellation in one place.

Cancel it **unconditionally at the top of `dismiss`, before** the `guard let window = activeWindows[id]` at `:191`. That guard is already why an early-removed main window orphans its blur window; a clock behind the same guard would be a live timer with no window.

**Recycled ids.** Id reuse is a real pattern here — `PluginInterrupt.swift:80-82` tracks an `activeFlashID` and dismisses the previous one before showing the next. Today a stale `asyncAfter` from run *N* captures that id and can close run *N+1*'s window. Give each clock a monotonically increasing generation token; the manager's timer callback carries `(id, generation)` and no-ops on mismatch. Public `dismiss(id:)` keeps its current meaning.

**Pause on hover.** The task timer must *not* pause on hover. The exercise is *look twenty feet away*; the user is by definition not watching the pointer, and in `.interrupt` the window covers the screen so the cursor is over it whether or not anyone is there — a hover pause would leave the break open forever. The dismiss indicator *should* pause on hover, but only in `.ambient`: reaching for a button on a draining toast and having it vanish mid-reach is the oldest complaint in this category.

**Sleep and wake.** This is why `deadline` is a `Date` and not a duration: `asyncAfter` across a system sleep is not a contract worth relying on; comparing `Date.now` to a stored deadline is. Subscribe to `NSWorkspace.didWakeNotification` to force re-evaluation on wake rather than waiting for the next tick. A task timer whose deadline passed while the machine slept is **cancelled silently** — no completion state, because the user did not do the exercise, and claiming otherwise is the surface lying.

**Animation without waking the CPU every frame.** Split by what changes. The *arc* is one `withAnimation(.linear(duration: remaining))` on a `Shape.trim(to:)`, set once when the phase starts; Core Animation interpolates it and SwiftUI never re-evaluates the body. This is mechanically what the existing bar already does (`SVGNotificationView.swift:95-98`) — the animation was never the bug, the missing cancellation handle was. Interrupting it with a zero-duration `withAnimation` snaps it to a known value, which is what makes pause/resume and the early-Done snap expressible at all.

The *number* changes once per second, so drive it with `TimelineView(.periodic(from:by: 1))` scoped to the `Text` alone. Not a `Timer` publisher into `@State`: that invalidates the whole notification body once a second — including `SVGView`, whose re-parse is not free — and drifts against wall clock, so the digit and the deadline would eventually disagree. Under Reduce Motion, step the arc once a second inside the same `TimelineView`. Never remove the number.

## Feedback: buttons, progress, confirmation

These are the three things the user named, so they get specified rather than implied.

### Done / Snooze / Skip

The row is `[StandardNotification.Button]` on `RichNotification`, drawn horizontally below the ring and above the footnote, in the caller's order. The library supplies the semantics of *dismissal*; the caller supplies the semantics of *meaning*. Concretely, each button's closure is the caller's, and the library guarantees what happens to the clock and the window around it:

| Button | Style | Clock | Surface |
| --- | --- | --- | --- |
| Done | `.primary` | `completeTask()` — ends the task phase now | Acknowledgement state, then dismiss |
| Snooze | `.secondary` | `cancel()` | No completion state; immediate fade |
| Skip | `.secondary` | `cancel()` | No completion state; immediate fade |

The existing rule from `StandardNotificationView` is inherited: run `button.action()`, then `onDismiss()` unconditionally (`:114-117`, `:125-128`, `:136-139`). The client's reimplementation independently arrived at the same rule with the same reasoning (`PluginAlertOverlay.swift:80-87`). A Snooze that leaves the interrupt on screen is not a snooze, and a plugin's "Turn off" must take the alert down without the caller needing the window id.

Snooze *rescheduling* is not in A. A has no schedule model and no offset column; the button's closure is whatever the caller passes, and for the schedule path that closure is B's to write. What A owns is that pressing it cancels the clock and closes the window cleanly, and that the surface never claims a break was completed.

Buttons take their taps before the full-bleed dismissal hit target, exactly as `PluginAlertOverlay.swift:101-105` already documents for its own layout.

### Live progress during the break

The task timer *is* the live progress; there is no second progress element. During the task phase the surface shows, top to bottom: illustration, title, message, the ring, the button row, the footnote. The ring shows the numeral (updated once per second by the `TimelineView`), the unit label beneath it, and the draining tick-marked arc. Nothing else moves.

The dismiss indicator is explicitly suppressed while a task timer is running. There is exactly one number on screen at a time, and it is the one the user is meant to obey.

### Completion confirmation

**Reaching zero.** The arc closes, the numeral is replaced by a check glyph and the timer's `completionLabel` ("Break complete"), and the ring stroke shifts to the success colour. Then the dismiss phase runs — its indicator visible if one was configured — and the window fades on its own.

In `.interrupt` there is no separate confirmation surface. The screen dim releasing and the desktop coming back into focus *is* the confirmation; a second "well done" panel after that is one modal too many.

**Pressing Done early.** `completeTask()` ends the task phase immediately and the arc **snaps** to full rather than animating there — a fast fill reads as "the timer sped up", which is confusing about what just happened. The label distinguishes the two honestly: reaching zero shows `completionLabel`; Done at second three shows an acknowledgement ("Got it") and nothing claiming a completed break. The user asked for confirmation that a break *completed*; a surface saying so when eighteen seconds were skipped is telling them something false.

**Cancellation** — Skip, Snooze, ESC, click-away — produces no completion state and no acknowledgement.

The clock exposes its terminal `Phase` to the caller's button closure so the caller can report an outcome, but the alert writes nothing anywhere. The completion state lives for the length of the dismiss phase and dies with the window. Where that outcome goes, if anywhere, is B's.

## Client migration

Four files import VibeNotify and only two change. That is the payoff from insulation that already exists: `NotificationPosition`, `BlurIntensity`, `NotificationPriority` and `NotificationAction` are VibeCare's own types, translated at exactly three boundaries — `BlurIntensity.vibeNotifyIntensity` (`VibeNotifyConfiguration.swift:7-16`), `PluginAlertPresenter.windowPosition(for:)` (`PluginAlertOverlay.swift:233-243`), and the position switch at `VibeNotifyConfiguration.swift:133-144`. Everything upstream talks only in VibeCare types and cannot tell which renderer drew the alert.

So the blast radius is two edited files. Zero files change under `core/plugins/`, `core/sdk/`, `backend/`, `proto/` or `clients/cli/`; zero test files change; zero of the three schedule preview call sites change.

### `Services/VibeNotifyConfiguration.swift`

`showScheduleNotification` (`:48-84`) keeps its signature exactly. All the change is inside the private `showNotification` (`:93-154`), the single funnel every schedule alert and every preview passes through.

The illustration fork at `:107-119` keeps its shape and changes destination: once `show()` stops forking on `useSVG`, the same fork feeds the rich renderer and buttons survive. The `else` branch at `:118` — `.icon(.system(defaultSystemIcon))` for a preference with no configured SVG — must keep producing a legible alert, because it is what an unconfigured schedule gets and it is the case most likely to be overlooked while everyone tests with an eye illustration. It maps to `Illustration.symbol`.

The builder chain at `:121-131` gains one line: `.mode(...)`, derived from `prefs.screenBlurEnabled` (`:129`). Blur enabled means `.interrupt`, blur disabled means `.ambient`. That toggle is already the user's way of saying "take over my screen for this", so it needs no new persisted key, no migration of saved actions, and no new control in the customization UI. The visible consequence for anyone who already has blur on is a real 0.55 dim and light text instead of the pinned 0.1 — the bug fix landing, not a regression.

`.autoDismiss(after:)` at `:127` stays as the dismiss path for schedule alerts in A. The task timer is not wired here, because nothing in A knows how long an exercise lasts. What A must guarantee is that when B supplies a task duration through this same function, `showNotification` passes one clock or the other and never lets a second compete with `:127`.

The five generic helpers (`:164`, `:182`, `:200`, `:226`, `:254`) are untouched. They draw banners and toasts on the standard renderer with an opaque card behind them (`transparent(true, material: .hudWindow)`), and the card is not the bug — the rejection was aimed at the break alert. Restyling the banner family is a separate decision.

`showToast(message:icon:)` at `:254` keeps leaking `StandardNotification.IconType`. Leave it: one parameter, one function, one caller (`NotificationManager.swift:89-105`, building the enum at `:92`). Replacing it costs a new VibeCare-owned icon enum plus a mapping in a file A otherwise never opens, to fix a leak that has never caused a break. The condition that flips this is precise: if the library deletes or renames `StandardNotification.IconType`, the enum work becomes mandatory and moves into A.

### `Views/Plugins/PluginAlertOverlay.swift`

The doc comment at `:8-24` is a list of things VibeNotify 0.0.5 cannot do. Every item on it is removed by this spec, so the view that exists because of the list goes with it.

`PluginAlertOverlayView` and `PluginAlertButtonStyle` (`:32-132`) are deleted. The view's theme-from-system logic (`:48`) is the same bug as `SVGNotificationView.swift:17-20`, faithfully copied — including white-glow-under-white-text at `:57`, `:65`, `:73` and the `.clear` shadow in light mode at `:65`, `:73`. Deleting it is how the plugin path *inherits* the contrast-correct shadows and the feathered scrim rather than needing them ported.

`PluginAlertPresenter.show` (`:157-164`) keeps its six-parameter signature byte for byte. That freeze is what lets `PluginShellService.deliver(_:)` (`:104`) and its routing (`:156`) stay untouched, along with `PluginAlertPresentation.route` (`Models/PluginAlertPresentation.swift:77`) and the tests that lock it (`vibecareTests/PluginAlertPresentationTests.swift:86-114`). Inside, the body becomes: policy guard, builder chain, return the id.

The fifteen-argument `Configuration` literal at `:181-202` is deleted, not maintained. The presenter only reached past the builder because `showCustom` (`API/VibeNotify.swift:190-196`) hardcodes away `screenBlur`, `position` and `width`/`height` — the three things the alert needs, as its own comment at `:138-148` explains. A builder that can express illustration, buttons, blur, dim, position and size removes the reason to hand-write a `Configuration`.

The `asyncAfter` auto-dismiss at `:206-211` goes too; it exists solely because "a caller-supplied view gets none" (`:150-151`), and the countdown engine now owns that lifetime — cancellably, which the `asyncAfter` never was.

`fittingHeight` (`:224-231`) **survives**, and its reason is not the same as the others': the `appearance` blob was authored for an alert with no buttons, and that blob is out of scope for A, so the authored height stays a floor and the measured height wins.

`windowPosition(for:)` (`:233-243`) survives unchanged. It is the insulation boundary, and boundaries are supposed to survive renderer swaps.

The icon reaching the presenter is an already-fetched `NSImage`, not a path, and must stay that way: `PluginShellService.resolveIcon` (`:207`) fetches through core's reverse proxy with a `vc_session` cookie (`:232-234`) under a 2-second bound (`:196`) into a bounded cache. Handing VibeNotify a URL would re-fetch unauthenticated and fail. Hence `Illustration.image`.

### `PluginInterrupt.swift` and `NotificationManager.swift` — untouched

`PluginInterrupt` draws a red rectangle for 450 ms. It has no text, no buttons and no timer, and gains nothing from the new renderer. Its ten-argument `Configuration` literal (`:90-101`) therefore has to keep compiling, and that is a constraint A places on the library: the public init (`OverlayWindowManager.swift:98-118`) may gain parameters — the dim among them — but **every new parameter must have a default and no existing parameter may be reordered or renamed.** Swift matches supplied arguments against declaration order, so inserting a defaulted parameter is safe while reordering two existing ones breaks silently at the type checker.

`NotificationManager` changes not at all. `showScheduleNotification` (`:32-55`) and `executeAction` (`:119-147`) pass preferences straight through, and `deserializeNotificationPreferences` (`:152-189`) reads only keys that already exist.

### The three preview buttons are the acceptance surface

`NotificationCustomizationView.swift:625`, `ActionCardView.swift:863` and `ActionEditSheet.swift:233` all call `showScheduleNotification` with live, unsaved preferences. Because they share the one funnel, they preview the new rendering for free — and that must stay true. **Do not add a preview flag, a preview-only renderer, or a stubbed timer.** A preview that renders through a different path teaches the user a layout they will not get.

Three specifics follow. A preview whose preferences have blur enabled now takes over the whole screen while the user sits in a settings sheet, so ESC and click-anywhere are not decoration — they are the only way out. `NotificationCustomizationView.swift:619-623` substitutes a multi-line options summary into `message` when none is set, which makes the preview the worst case for the ambient feathered scrim: several lines of varying width over an arbitrary desktop, so that is where the scrim gets judged. And the in-sheet confirmation chip that `ActionCardView.swift:836-845` clears after two seconds is unrelated to the alert's own lifetime and stays as it is.

### Policy gating stays where it is

Seven call sites guard on `NotificationPolicy.shared.isNotificationAllowed(priority:)`: six in `VibeNotifyConfiguration.swift` (`:100`, `:165`, `:183`, `:206`, `:232`, `:255`) and one at `PluginAlertOverlay.swift:165`. All seven stay in VibeCare, above the builder. VibeNotify is published from a separate repo for general use; a mute switch buried inside it would be invisible to any other consumer. The guards return `nil` rather than a dead id, which is how callers distinguish "suppressed" from "shown" (`NotificationManager.swift:49-53`).

`PluginInterrupt.fire` (`:47-51`) consults `PluginInterruptPolicy` and nothing else, deliberately (`:16-21`). That exemption is load-bearing in a test — `vibecareTests/PluginInterruptPolicyTests.swift:45` flips `NotificationPolicy.shared` and asserts `shouldInterrupt` does not care. Since `PluginInterrupt.swift` is not edited, it survives by construction.

## Development setup

The committed manifest does not change. `clients/macos-swift/VibeCare/Package.swift:32` keeps `.package(url: "https://github.com/vibecare-io/vibe-notify-macos.git", from: "0.0.5")`, and `vibecare.xcodeproj/project.pbxproj:670-672` keeps its `XCRemoteSwiftPackageReference`. Live iteration is a per-developer, uncommitted override:

```
swift package edit vibe-notify-macos --path ../../../../simple-alerts
```

run from `clients/macos-swift/VibeCare/`. SwiftPM drops a symlink at `Packages/vibe-notify-macos` and records the override in `.build/workspace-state.json`; `just swift-build`, `just swift-run` and `just swift-test` then compile the sibling checkout directly, with no tagging and no `Package.resolved` churn.

**Why not a committed path dependency.** SwiftPM derives a path dependency's identity from the *directory basename*. The local checkout lives in a directory called `simple-alerts`, while the product is consumed at `Package.swift:56` as `.product(name: "VibeNotify", package: "vibe-notify-macos")` — `package:` is the identity, and under a path dependency it would become `simple-alerts`. Every product reference would have to change, the Xcode remote package reference would have to be torn out, and both reverted before release. `swift package edit` overrides *resolution* and leaves identity alone.

**Confirming and undoing.** `swift package show-dependencies` prints resolved locations; `ls -l Packages/` shows the symlink. Undo with `swift package unedit vibe-notify-macos` before any commit touching the Swift package, because `Packages/` is not in core's `.gitignore` — it ignores `**/.build` (`:47`), `clients/macos-swift/.build/` (`:56`), `/clients/macos-swift/VibeCare/.build/` (`:136`) and `/clients/macos-swift/VibeCare/.swiftpm/` (`:137`), and nothing else SwiftPM-related. Given that this tree is routinely worked by two concurrent sessions, a stray `git add -A` would commit a symlink to a path that exists on one machine. Add `clients/macos-swift/VibeCare/Packages/` to `.gitignore` as part of this work rather than relying on discipline.

Incidentally: `simple-alerts`'s only remote, `github`, still points at the pre-rename `git@github.com:vibecare-io/macos-notify.git`. It works through GitHub's redirect, but the redirect is a courtesy, not a contract. One line, once: `git remote set-url github git@github.com:vibecare-io/vibe-notify-macos.git`.

## Testing

### Make the test target compile first

`Tests/VibeNotifyTests/VibeNotifyTests.swift:1` reads `import TestingE` — a typo for `import Testing` — so the target does not build and `swift test` fails with "no such module 'TestingE'". The sole `@Test func example()` has an empty body. The release workflow has the test step commented out (`.github/workflows/release.yml:25-28`, "we don't have test for now"), which is why a one-character typo has survived five tags.

Fix the import and delete the empty example as its own commit, before any renderer work. Then uncomment the test step and — more importantly — add a `push: branches: [main]` trigger running `swift build` and `swift test`. Today the workflow triggers only on tags matching `*.*.*` (`:3-6`), so nothing validates `main` between releases. Without this, every assertion below is theatre.

### What is testable without a screen

**The countdown state machine**, and this is the reason it must leave the views. Today's mechanism is untestable by construction: the animation *is* the timer. Replace it with a value that owns remaining time and is advanced by an injected clock, then assert: it counts down and reaches zero; the completion fires exactly once; `cancel()` before zero fires nothing; an early dismissal cancels rather than letting a dead timer fire against a closed window; a task timer with no auto-dismiss dismisses at zero; a task timer *with* one does not dismiss twice. The "fires nothing after cancel" case is the current bug, and it is invisible on screen because the window is already gone.

**The mode and legibility decision**, as a pure function from `(mode, dim)` to text colour, shadow colour, shadow radius and scrim opacity. Assert `.interrupt` yields light text for both colour schemes — that single assertion is the regression guard for `SVGNotificationView.swift:17-20`. Assert the shadow always opposes the text colour and is never `.clear`, which kills `:47` and `:56` permanently. Assert `.interrupt` produces 0.55 and `.ambient` produces none, so nobody re-pins it to the 0.1 at `OverlayWindowManager.swift:289`.

**Builder routing.** Testing this requires splitting `show()` into a pure step that resolves the builder into a content value and an impure step that hands it to the window manager. That split is the highest-leverage testability change in this work; without it, "buttons are no longer dropped" is only assertable by looking at a notification. With it: build an SVG notification with two buttons, assert the resolved content carries both; and the inverse, a standard notification with an SVG icon must no longer resolve to `EmptyView()`.

**Geometry mapping.** Mode plus position plus size resolved to a window frame, as a value. The repo has the precedent and says so: `vibecareTests/PluginAlertPresentationTests.swift:12-19` exists to assert the parts of "does the alert look right" that can be asserted without a screen.

### Core-side

Retargeting must not regress `PluginAlertPresentationTests`, which pins the plugin-alert geometry — 450×220 window, 220×150 illustration, 20s auto-dismiss (`Models/PluginAlertPresentation.swift:47-50`) — and its routing cases (`:86-114`). Extend it with the new mode mapping rather than writing a parallel file. Gotcha: core's test target enumerates its sources explicitly (`clients/macos-swift/VibeCare/Package.swift:77-82`), so a new test file is invisible to `swift test` until added to that list; the comment there records that `swift test` once reported "no tests found" for exactly this class of reason.

### What only an eye can check

Whether text is genuinely readable over an arbitrary desktop; whether the ambient scrim's edge is actually invisible; whether the radius looks right; animation timing. Cover them with a demo harness — an executable target in the library rendering each mode over deliberately hostile backdrops, the half-black/half-white split first among them — and attach screenshots to the pull request. The harness is not a test; it is a repeatable way to look at the thing.

## Risks

**The private CoreGraphics dependency.** `Core/WindowBlurHelper.swift:6-14` declares `CGSDefaultConnectionForThread` and `CGSSetWindowBackgroundBlurRadius` via `@_silgen_name`. Interrupt mode leans on it harder than anything today. For direct distribution it is fine — the file's own comment names WezTerm and Kitty as precedent. For the App Store it is a review risk, and `@_silgen_name` does not change that: it bypasses the public linker symbol table, which makes static detection harder but not impossible. Across OS upgrades it is fragile in a specific way: because the symbol binds at load time, a *removed* symbol is a dyld launch failure for the whole app, not a silently skipped blur.

The mitigation is architectural, not defensive: **make interrupt mode's legibility depend on the dim, not the blur.** The dim is `NSColor.black.withAlphaComponent(...)`, entirely public API. If the blur degrades to nothing, an interrupt over a 0.55 black dim is still legible and still reads as an interrupt; it just looks flatter. That reduces the private call from load-bearing to cosmetic. The `NSVisualEffectView` fallback is noted below as an open question rather than built in A.

**The orphaned blur window is now a bricked desktop.** `dismiss(id:animated:)` opens with `guard let window = activeWindows[id] else { return }` (`:190-191`) and only reaches `blurWindows[id]` after that guard passes. If the main window was already removed by any other path, the full-screen blur window survives with no owner and no route to close it. Today that is a 10% nuisance; under interrupt it is a dark, click-hostile sheet over the entire screen. This is the highest-severity item here and it must be fixed *before* interrupt ships: tear down blur and main windows independently, each keyed on the id, plus a sweep closing any blur window with no matching `activeWindows` entry.

**`alwaysOnTop` swallows `windowLevel`.** `:251` reads `window.level = configuration.alwaysOnTop ? .floating : configuration.windowLevel.nsWindowLevel`, and `alwaysOnTop` defaults true, so `.screenSaver` is unreachable. `.floating` does not sit above another application's full-screen window, and an interrupt a full-screen editor covers is not an interrupt. The collection behaviour at `:257` is already the right half of the answer. Make `alwaysOnTop` a floor rather than an override: take the higher of `.floating` and the requested level. It is an observable behaviour change, so both hand-written client literals must be re-read and re-verified after it, not merely recompiled.

**The two Swift 6 concurrency warnings.** `OverlayWindowManager.swift:422-423` captures a non-`Sendable` `() -> Void` inside a `@Sendable` completion handler and calls main-actor-isolated `NSWindow.close()` from a synchronous nonisolated context. `Package.swift:1` declares swift-tools-version 6.1, so these are the sort of warning a future toolchain promotes to error. They sit in `animateDismiss` (`:414-425`), which every dismissal funnels through — and this work adds four dismissal paths. Fix them here rather than quadrupling the caller count of a function that already warns.

## Rollout

1. **In `simple-alerts`, commit the pending fix alone.** The uncommitted edit at `Sources/VibeNotify/Views/SVGNotificationView.swift:37` changes the dark-mode glow from `.white` to `.green`; `changelog/30112025-adaptive-theme-support.md:16` already documents green, so shipped-white is the bug and this is the unshipped fix. Its own commit, so it is bisectable.
2. **Fix the test target and the CI trigger.** Nothing else lands until `swift test` passes on `main`.
3. **Land the library work on a branch and merge to `main`.**
4. **Tag `0.0.6` and push the tag.** The workflow triggers only on `*.*.*` tags — pushing the tag *is* the release.
5. **In `core`, re-resolve.** Bump `from: "0.0.5"` to `"0.0.6"` at `clients/macos-swift/VibeCare/Package.swift:32` and update **both** resolved files in the same commit: `clients/macos-swift/VibeCare/Package.resolved:266-272` and `clients/macos-swift/VibeCare/vibecare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:266-272`, both currently pinning revision `c74f2acd745eaaa2db31741b33bbcadd6bc3d664` / version `0.0.5`. `from:` is up-to-next-major and already admits 0.0.6, so the manifest edit documents intent; what moves the app is re-resolving. Both files must move together because two build systems each keep their own, and two disagreeing `Package.resolved` files is a failure this tree has already had once.
6. **Retarget the two client files** in a separate commit from the version bump, so a bisect can distinguish "the new library broke something" from "the retarget broke something".

**Verifying in the real app.** Use `just swift-run-app`, not `just swift-run`: the justfile comment at `:1097-1099` records why — the Xcode build embeds an Info.plist and `swift run` produces a bare CLI binary, which is a real behavioural difference and not the artifact users get.

Reproduce the original bug deliberately before confirming the fix: split the desktop black-terminal-left, white-browser-right, and fire a 20-20-20 schedule notification through `NotificationManager.showScheduleNotification` (`:41`). Title and message must be legible over both halves in both system appearances — the light-mode case currently renders black text with a `.clear` shadow and is the one most likely to be forgotten. Then, in order: an ambient alert over the same backdrop with no dim; ESC, click-anywhere and an explicit button each dismissing an interrupt; a countdown cancelled by early dismissal *not* firing afterwards; a Done press producing an acknowledgement rather than a completion claim; and a plugin alert still rendering through `PluginAlertPresenter.show` at its existing geometry.

**Rollback** is reverting core's `Package.swift` and both resolved files to 0.0.5 and rebuilding. The tag stays published. There is no migration and no persisted state anywhere in this work.

## Deferred

- **Snooze rescheduling.** A guarantees the button cancels the clock and closes the window; what "snooze" *does* to a schedule is B's, once `schedule_actions` carries a time offset.
- **Driving the task timer from a schedule.** A builds the timer and the plumbing; nothing in A knows how long an exercise lasts.
- **An explicit presentation key in the action parameters** that `deserializeNotificationPreferences` (`NotificationManager.swift:152-189`) reads, so "interrupt me" and "blur the background" become independently selectable. Deriving one from the other is right for A and would be wrong forever.
- **Recording break outcomes anywhere.** The completion state dies with the window.
- **The `appearance` blob**, and therefore any per-plugin control over mode, ring or footnote. C.
- **Restyling the banner/toast family** (`showSuccess`/`showError`/`showWarning`/`showInfo`/`showToast`). They keep their opaque card; the card rejection was aimed at the break alert.
- **Removing the deprecated `showSVG` / `SVGNotification` / `SVGNotificationView` symbols.** A 1.0 concern.

## Open questions

**Whether ambient alerts show a card or suppress themselves under Reduce Transparency.** A feathered scrim *is* a transparency gradient and cannot be made opaque and stay edgeless. The two honest options are promoting the ambient text block to an opaque surface with a defined edge — the card the user rejected — or suppressing ambient alerts entirely for those users. Dropping the scrim and relying on shadows alone fails 4.5:1 over a light desktop and is not an option. **The user decides**, before implementation; the implementer must not pick.

**Whether pressing Done while the task timer is still running should dismiss immediately or let the ring finish.** This spec proposes dismiss-immediately with an acknowledgement label. **The user decides** on seeing it run.

**The length of the completion beat** before a task-timer-only alert dismisses itself. Proposed: 1.5s. A feel decision; **the user decides** on seeing it run.

**Whether an interrupt should take key/focus** in addition to sitting above other windows. Separate from window level, with real consequences for whatever the user is typing into. **The user decides.**

**Whether the `NSVisualEffectView` fallback ever becomes the default backdrop.** It gives supported, App-Store-safe blur but only a fixed vocabulary of materials, so `ScreenBlurIntensity`'s 10/25/50 would collapse into two or three and `.custom` would become approximate. It hinges entirely on whether App Store distribution becomes a goal. **The user decides**; A neither builds nor defaults to it.

**The exact CGS minimum background alpha.** `OverlayWindowManager.swift:288` says "~0.1 minimum" with no measurement behind it. **The implementer re-measures** on macOS 14 and 15 and adjusts the clamp floor. Nothing above the floor changes either way, so this does not block the design.

**Whether Xcode honours `swift package edit`.** `just swift-run-app` builds through `xcodebuild`, which resolves via its own `XCRemoteSwiftPackageReference` and its own `Package.resolved` — a different resolution from `.build/workspace-state.json`. **The first developer to iterate** answers this and records the answer in the library README, along with the Xcode-side equivalent (adding the local package folder to the project window so it shadows the remote reference) if the override is ignored. This matters because `swift-run-app` is the only build that produces a real `.app`.

**Whether `fittingHeight` (`PluginAlertOverlay.swift:224-231`) becomes deletable.** It survives in A only because the `appearance` blob was authored for a buttonless alert. If `.ambient` windows self-size to their content, it goes. **The implementer decides** while building the ambient geometry, and deletes it if self-sizing lands.
