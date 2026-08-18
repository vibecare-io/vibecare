# Web Alert Surface — Design

**Status:** approved, minimal spec
**Scope:** `simple-alerts` (VibeNotify) + `clients/macos-swift` (VibeCare client)

## Goal

Let an alert embed a live web page beside its text and countdown, so a break
can *be* something — play blink-jump, watch a video, glance at an inbox —
instead of only describing something.

## Layout

One inset panel over the dimmed, blurred desktop. Two columns:

```
┌─ blurred + dimmed desktop ──────────────────────────────────┐
│   ┌──────────────────────────┬────────────────────┐         │
│   │                          │            ◜ 0:20 ◝ │         │
│   │        web panel         │  Title              │         │
│   │   (game / video / page)  │  Message            │         │
│   │                          │                     │         │
│   │                          │  [ Done ] [ Skip ]  │         │
│   │                          │  footnote           │         │
│   └──────────────────────────┴────────────────────┘         │
└──────────────────────────────────────────────────────────────┘
```

The right column is the existing rich-renderer chrome, unchanged: title,
message, countdown ring, buttons, footnote, and the same `Legibility` text
treatment. The only new element is the web panel.

**Countdown moves to the top of the rail** in this layout. Everywhere else it
stays where it is. The rail reads top-down as *how long is left → what to do →
how to leave*, which is the order the mockup asks for and the order that
survives the web panel being the thing the eye lands on first.

## Library: `RichNotification.webPanel`

A new optional property on the model the renderer already takes, **not** a new
model and not a new renderer. A parallel `WebNotification` would have to
re-declare title, message, footnote, buttons, task timer, auto-dismiss, mode
and acknowledgement label, and would fork `styled()`, the scrim strategy, the
entrance animation and the button-outcome routing — roughly 200 lines of
subtle duplication for one extra element.

```swift
public struct WebPanel: Sendable, Equatable {
  public enum Placement: Sendable { case leading, trailing }

  public let url: URL
  public let placement: Placement      // default .leading
  public let widthFraction: CGFloat    // of the panel, clamped 0.3...0.85, default 0.64
  public let allowsAutoplay: Bool      // default false
}
```

- `webPanel` and `illustration` are mutually exclusive. When both are set the
  web panel wins and the illustration is not drawn — the panel *is* the
  picture, and two competing focal points is the composition problem the
  renderer already has metrics to avoid.
- Ignored in `.ambient`. A 380×210 toast has no room for a web view, and
  `effectiveTaskTimer` already establishes the precedent that the model
  reinterprets rather than trusting a caller's mode-incoherent combination.

### Interaction changes when a web panel is present

1. **The full-bleed click-to-dismiss target is suppressed.** Today
   `RichNotificationView.body(in:)` installs an unconditional screen-sized tap
   target that cancels the alert. With an interactive panel on screen, a
   misclick in the margin would end a break the user was in the middle of
   taking. ESC and the buttons remain.
2. **The panel takes key focus**, which `.interrupt` already arranges — a game
   needs the keyboard.

## Web view

`WebPanelView`, an `NSViewRepresentable` over `WKWebView`, using the **default**
`WKWebsiteDataStore`. That is what makes authentication a non-problem:
VibeNotify is a SwiftPM dependency running inside the client's own process, so
the default data store is the same jar the client's `PluginWebView` already
writes core's `vc_session` cookie into. A plugin URL loads authenticated with
no extra work, and a logged-in webmail stays logged in between breaks.

No basic-auth prompt and no manual token entry are needed for blink-jump.

`allowsAutoplay` sets `mediaTypesRequiringUserActionForPlayback = []`, off by
default — a video that starts talking on its own is a worse interruption than
the one it was meant to soften.

## Client wiring

Three new action parameters, alongside the existing `task_timer_seconds`
family, parsed in `NotificationPreferences` and applied in
`VibeNotifyConfiguration`:

| key | value |
|---|---|
| `web_url` | `https://…`, or `plugin:<id>` / `plugin:<id>/<path>` |
| `web_side` | `leading` (default) or `trailing` |
| `web_width` | width fraction, `0.3`–`0.85` |
| `web_autoplay` | `true` / `false` |

`plugin:` values resolve through `PluginRoster.handoffURL(for:)`, so the token
handoff and cookie exchange are the ones already in use. A `plugin:` value
naming a plugin that is not running falls back to a normal alert with no panel
rather than showing an error page inside a break.

A `web_url` forces `.interrupt`, for the same reason `task_timer_seconds` does.

No proto, database, or CLI-contract change: `Action.parameters` is
`map<string,string>`.

## Non-goals

- Navigation chrome (back/forward/reload). This is a break surface, not a
  browser.
- Injecting scripts into the page or reading anything out of it.
- `.ambient` support.
