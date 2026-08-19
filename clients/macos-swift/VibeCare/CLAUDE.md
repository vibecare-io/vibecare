# Swift Client — CLAUDE.md

Native SwiftUI macOS app (macOS 15+). Server-first MVVM with in-memory state management.

## Key Architecture Decision

**No local persistence.** All data comes from the backend via gRPC. No SQLite, CoreData, offline support, or sync logic. State lives in `@Published` ViewModel properties and is rebuilt from the backend on each launch.

Only UserDefaults is used — for network config (`grpc_url`, `backend_url`) and `currentProfileId`.

## Code Layout

```
vibecare/
├── App.swift                  # Entry point, startup sequence
├── Models/                    # Swift structs matching protobuf entities
├── Services/                  # gRPC service wrappers
│   └── GRPCClientManager.swift  # Connection lifecycle (withXServiceClient pattern)
├── ViewModels/                # @Published state, business logic
│   └── AppState.swift         # Global singleton: profile, connection status
├── Views/                     # SwiftUI views organized by feature
├── Utilities/
│   └── NetworkConfiguration.swift
└── Resources/                 # Bundled templates, icon catalog
VCStubs/                       # Generated protobuf/gRPC stubs (do not edit)
```

## Key Patterns

### `withXServiceClient` — connection lifecycle
```swift
let profiles = try await GRPCClientManager.shared.withProfileServiceClient { client in
    try await client.listProfiles(...)
}
// Connection automatically closed
```

### State management
- `AppState` (singleton): global profile, connection status
- Feature ViewModels: `RoutineViewModel`, `ScheduleViewModel`, `ActionViewModel`
- `NotificationCenter` for cross-component events (profile changes, backend events)
- `EventService` streams real-time events from backend via SSE

### Notifications
Custom [VibeNotify](https://github.com/vibecare-io/vibe-notify-macos) library — bypasses native `UNUserNotificationCenter` for custom styling, positioning, and interactive actions. See [Notifications](#notifications) below.

## Notifications

Two paths reach the screen, and both render through VibeNotify's **rich
renderer** (`RichNotification` / `RichNotificationView`) — the only one that
draws an illustration, buttons and a countdown together:

| Path | Entry point | Mode |
|---|---|---|
| Schedule actions | `VibeNotifyConfig.showScheduleNotification` → `showNotification` (`Services/VibeNotifyConfiguration.swift`) | `.interrupt` when blur is on **or** a task timer is set; `.ambient` otherwise |
| Plugin alerts | `PluginAlertPresenter.show` (`Views/Plugins/PluginAlertOverlay.swift`) | always `.ambient` |

Plugin alerts are `.ambient` even when the appearance asked for blur: a plugin
authors its alert's geometry, and `.interrupt` deliberately ignores position and
size in order to own the whole screen. `PluginAlertPresentation.blurIntensity`
consequently reaches no window.

A plugin alert falls back to the **standard banner** (`showWarning`/`showInfo`)
in two cases, both in `PluginShellService`: no appearance blob at all, or an
appearance that asked for an illustration whose fetch failed. Losing the picture
is cosmetic; losing the buttons — "Turn off" on a camera the user wants stopped
— would not be, and the banner still draws them.

The generic helpers (`showSuccess`/`showError`/`showWarning`/`showInfo`/`showToast`)
still go through the old builder path and the standard renderer. They are
banners, not break alerts.

### Global settings

The durable copy lives in `Profile.preferences` — already a
`map<string, string>` on the wire, so this needed no proto change and no
migration, and it syncs across devices. `UserDefaults` is written as a **mirror,
not a second source of truth**: notifications can fire before the profile has
loaded, and reading them must not be async or main-actor-bound. `hydrate(from:)`
overwrites the mirror whenever a profile arrives, so the server wins.

Keys, all under `notify.` (`Services/GlobalNotificationSettings.swift`):

`notify.position`, `notify.width`, `notify.height`, `notify.blur_enabled`,
`notify.blur_intensity`, `notify.screen_dim`, `notify.backdrop_style`,
`notify.auto_dismiss_after`, `notify.moveable`, `notify.break_unit_label`,
`notify.break_completion_label`.

`notify.backdrop_style` is **global-only** — no per-action override, and absent
from `appearanceParameterKeys`. A break backdrop is a property of this machine's
idea of restful, not of the routine that fired the alert.

### Resolution order

1. `GlobalNotificationSettings` — the defaults, set once in Settings.
2. The action's own `parameters` — any key present wins **for that key alone**,
   never for the whole set.

So an action that specifies nothing gets the global look, and an action that
specifies `position: topRight` keeps `topRight` and inherits everything else.
`GlobalNotificationSettings.resolving(actionParameters:)` is the single place
that rule is expressed. There is no separate "is overridden" flag: the presence
of the keys *is* the persisted override state, which is why an action authored
by the CLI or MCP reads correctly without this app having written it.

### Action `parameters` keys

A schedule action's `parameters` map is how a notification is configured. Note
the appearance keys are **unprefixed** here and spelled differently from their
global counterparts (`screen_blur_enabled`, not `notify.blur_enabled`).

**Content** — no global counterpart, so absent simply means absent:

| Key | Value |
|---|---|
| `title` | Alert title |
| `body` | Alert message |
| `svg_path` | Full URL for a bundled icon, or a file path for a custom one |
| `svg_width`, `svg_height` | Illustration size in points |

**Break countdown** — the knobs that turn a notification into a timed break:

| Key | Value | Fallback |
|---|---|---|
| `task_timer_seconds` | Duration of the countdown ring, in seconds. **Absent or unparseable means no ring at all** | none — action-only |
| `task_timer_unit_label` | The word under the number | `notify.break_unit_label` ("seconds") |
| `task_timer_completion_label` | What the ring's centre says at zero | `notify.break_completion_label` ("Break complete") |

**Rich vs plain** — `notification_style: rich` records which editor an action
was authored in. There is no ninth `ActionType`: a rich notification and a
plain one are both `notification` on the wire, because that is what the
backend schedules and what every other client understands. The split is an
authoring concern and lives in `ActionKind` — the "Add Action" menu, the
editor, and the label in the list.

`ActionKind.isRich` deliberately does **not** trust the marker alone: an
action carrying `task_timer_seconds` or `web_url` is rich whatever it was
authored in. Without that, every action written by the MCP server, the CLI or
a routine template would open in the plain editor, which has no controls for
either — so the author would see its most important settings missing and the
next save would drop them.

**Web panel** — turns the break into something the user can do. Action-only,
no global counterpart (what to load during a break is content, not appearance):

| Key | Value |
|---|---|
| `web_url` | `https://…`, or `plugin:<id>` / `plugin:<id>/<path>` |
| `web_side` | `leading` (default) or `trailing` — which side the page takes |
| `web_width` | The page's share of the surface width, `0.3`–`0.85` |
| `web_autoplay` | `true` / `false` — may media start on its own (default `false`) |
| `web_muted` | `true` / `false` — start with sound off (default **`true`**) |
| `web_loop` | `true` / `false` — restart the video when it ends (default `false`) |

**Autoplay does not work while macOS Low Power Mode is on**, and this is
measured, not suspected. WebKit's `RequireUserGestureForVideoDueToLowPowerMode`
refuses to start any video without a real user gesture — muted or not,
`autoplay=1` or not, and regardless of
`mediaTypesRequiringUserActionForPlayback`. It has no muted exemption and no
API that lifts it. The symptom is a video that loads and displays perfectly,
shows its play button, and never starts; it cost a long hunt that blamed
YouTube, the iframe, the origin and the URL parameters first. Nothing detects
it — the only thing that satisfies the gate is the user pressing play, which
is the fallback anyway.

YouTube links of every shape are rewritten to an embedded player: `watch?v=`,
`youtu.be`, `/shorts/` and `/live/`, keeping any `?t=` start offset. Shorts in
particular need it — followed directly, a Short plays and then scrolls on to
the next one, handing the user an infinite feed at the moment the break was
meant to stop them looking at one.

`plugin:` specs resolve at delivery time through
`PluginRoster.handoffURL(for:path:)`, which appends the `?vc=` token core swaps
for a session cookie. They are stored unresolved on purpose: the base URL and
the token both change when core restarts, so an already-resolved URL saved into
an action would be a stale credential in the database. A spec naming a plugin
that is not in the roster logs and shows **no panel** — a break that opens on
core's error page is worse than one with no panel. A bare `example.com` is
rejected rather than upgraded to `https://`, because `URL(string:)` accepts it
as a relative URL and the panel would then be silently blank.

**Appearance** — global unless the action says otherwise:

| Key | Values |
|---|---|
| `position` | `center`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight` |
| `width`, `height` | Points. Height is a **floor**, not a size — see `richAmbientHeight` |
| `moveable` | `true` / `false` |
| `auto_dismiss_after` | Seconds |
| `screen_blur_enabled` | `true` / `false` |
| `screen_blur_intensity` | `light`, `medium`, `heavy` |

#### Four behaviours that surprise people

**A task timer forces `.interrupt`, whatever `screen_blur_enabled` says.**
`RichNotification.effectiveTaskTimer` returns `nil` in `.ambient` by design — a
labelled ring reads as a task, and ambient alerts have none — so an action that
set `task_timer_seconds` with `screen_blur_enabled: false` would otherwise get
no ring at all and no error to explain why. A duration the author explicitly
asked for is a stronger signal than a blur flag that may just be an
unconsidered default, so the mode is upgraded rather than the ring dropped. The
upgrade is logged.

**`auto_dismiss_after` is ignored while a task timer is present.** The two are
sequential phases in VibeNotify, not a race: the dismiss clock only arms once
the task hits zero, so honouring both would total `duration + delay` — the
20-20-20 action's 20s task plus a 25s dismiss is 45 seconds on screen, which is
very unlikely to be what an author who set a task duration meant. Instead the
library's own `NotificationClock.completionHold` (1.5s) governs how long the
completion label holds before the window closes. The ignored value is logged.

**`web_url` forces `.interrupt` too, and takes click-anywhere-to-dismiss
away.** `RichNotification.effectiveWebPanel` is `nil` in `.ambient` for the
same reason the task timer is — a 380×210 toast split into two columns is two
columns too narrow to be either. And `RichNotificationView` suppresses its
full-bleed tap target whenever a panel is present: everywhere else "click
anywhere to skip" is a courtesy, but with a game in the panel one shot landing
in the margin would cancel the break and explain nothing. ESC and the buttons
remain, and the footnote says so.

**A `web_url` with no `task_timer_seconds` gets a Close button.** Without one
it would have no buttons (those come with the timer), no click-away (see
above), and a 3-second `quickDismissDelay` — three seconds of a video, then
gone. The panel-without-timer case gets a button and no deadline instead.

## Plugins (v2)

The client contains no plugin-specific code. Plugin screens are
`WKWebView`s pointed at Core's reverse-proxy path (`<base_url>/p/<id>/`);
the client never speaks a plugin's own protocol. The only plugin-aware
types are `PluginRoster`/`PluginEntry`/`PluginAlert` (`Models/PluginRoster.swift`),
populated over the two-RPC shell contract (`GRPCClientManager.withShellClient`,
`Services/PluginShellService.swift`) and rendered by `Views/Plugins/PluginListView.swift`,
`PluginScreen.swift`, and `Views/Plugins/PluginWebView.swift`.

## Common Tasks

**Add a new view**: Create in `Views/<Feature>/`, add to navigation in parent view, create ViewModel if needed.

**Add a new service method**: Update `proto/vibecare.proto` → `just proto-gen` → add method to the relevant service file → add protobuf-to-Swift conversion → update ViewModel.

**Add a new action type**: Add case to `ActionType` enum in `Models/Action.swift` → define required params → add execution logic in `EventService.swift` → update action creation UI.

## Gotchas

- **Never edit `VCStubs/`** — auto-generated by `just proto-gen`
- **Email is optional** — services convert empty string to nil automatically
- **Schedule-action relationship** uses a join table (`schedule_actions`), not embedding. Actions can be reused across schedules.
- **Icons load from backend HTTP API** — URLs built dynamically from `backend_url` UserDefaults
- **No retry/offline logic** — connection failure returns empty arrays

For full architecture details, see [`docs/architecture.md`](../../../docs/architecture.md).
