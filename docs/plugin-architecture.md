# Plugin Architecture (v2)

> Reference for how VibeCare's plugin system works and how to build against it.
> Design rationale lives in the [v2 design spec](superpowers/specs/2026-08-13-plugin-architecture-v2-design.md);
> this document is the practical map.
>
> Supersedes the v1 docs ([development guide](plugin-development-guide.md),
> [decisions](plugin-system-decisions.md), [findings](plugin-architecture-findings.md)),
> which describe an architecture that no longer exists.

## The 60-second model

A plugin is a **directory with a manifest and a binary**. Core discovers it at startup, spawns it as
a subprocess, supervises it, and reverse-proxies its HTTP at `/p/<id>/`.

Adding a plugin requires **no change to core and no client release**.

Three rules hold the design together:

1. **The plugin is always the gRPC client, never a server.** Core cannot call into a plugin.
2. **The kernel contains zero product semantics.** No `posture`, `todo`, `detection` — in any
   `.go` file under `backend/kernel/`, comments and test fixtures included.
   `TestKernelContainsNoProductNouns` fails the build.
3. **`/api/*` is the real interface; the HTML is its first consumer.** That split is what lets a
   TUI or CLI render a plugin later with no core change and no plugin change.

## Components

```
┌─────────────────┐                    ┌──────────────────────────────────────┐
│  macOS client   │                    │  core  (backend/kernel/)             │
│   (a shell)     │                    │                                      │
│                 │  client/v1 gRPC    │  registry ── scans <id>/manifest.yaml│
│  sidebar ◄──────┼── Plugins (stream) ┤  supervisor ─ spawn·backoff·SIGTERM  │
│  WKWebView      │                    │  health ───── /health · state machine│
│  NSPanel ◄──────┼── Intents (stream) ┤  bus ──────── topic→chans · demand   │
│                 │                    │  proxy ────── /p/<id>/* → 127.0.0.1  │
└────────┬────────┘                    │  rpc ──────── Register·Publish·Alert │
         │                             └────┬──────────────────────┬──────────┘
         │ HTTP via proxy                   │ unix socket (gRPC)   │ HTTP
         │  /p/<id>/                        │ ~/.vibecare/core.sock│ 127.0.0.1:0
         └──────────────────────────────────┼──────────────────────►
                                            ▼
                          ┌─────────────────────────────────────┐
                          │  plugins/todo/       (Go)           │
                          │  plugins/vibecheck/  (Swift)        │
                          └─────────────────────────────────────┘
```

The client contains **no per-plugin code**. It gets a roster over a stream and renders a webview per
plugin. Alerts are the one exception (§ Alerts).

## Lifecycle

```
core start
   │
   ├─ scan plugins/<id>/manifest.yaml        (once — there is no hot-add)
   ├─ mkdir ~/.vibecare/data/<id>/  0700
   └─ exec <manifest.exec>
        env: VIBECARE_SOCKET, VIBECARE_PLUGIN_ID, VIBECARE_DATA_DIR   ← exactly three
        cwd: the plugin's own directory; exec resolves relative to it
             │
   plugin ───┤ 1. install GET /health
             │ 2. bind 127.0.0.1:0 AND begin accepting
             │ 3. Register{id, http_port}  ─────────────►
             │              ◄──── Ready ──────────────────
             │              ◄──── Event  (subscribed bus topics)
             │              ◄──── Shutdown ────────────────
             │
   core  ────┤ SetPort → SetState(up) → roster fan-out → the client shows a tab
             │ probe /health on an interval
             │ on exit: backoff 1→2→4→8→16s; 5 consecutive failures → StateFailed, parked
```

**Step order is mandatory.** The proxy targets the plugin's port the instant core marks it `up`, so a
socket that is bound but not yet accepting produces 502s rather than the down page.

## Contracts

### Manifest — `plugins/<id>/manifest.yaml`

```yaml
id: vibecheck            # ^[a-z][a-z0-9-]*$ — routing key, data-dir name, topic prefix
name: VibeCheck
icon: eye                # SF Symbol; the client falls back if invalid
exec: ./dist/vibecheck   # resolved relative to the manifest's directory
subscribes: [activity.afk.v1]
publishes:  [vibecheck.behavior_detected.v1]
ui: webview              # or: none (headless — runs, but gets no tab)
```

Only `id` and `exec` are required. A malformed manifest is skipped with a warn log; a **duplicate id
is a hard startup error**. Discovery runs once in `Kernel.Start` — any manifest change needs a core
restart.

### Plugin ↔ core — `proto/plugin/v1/plugin.proto`

Three RPCs on `PluginHost`, served by core:

| RPC | Kind | Direction |
|---|---|---|
| `Register` | **server-streaming** | plugin sends one `RegisterReq`; core streams `CoreMsg` forever |
| `Publish` | unary | plugin → core |
| `Alert` | unary | plugin → core |

`CoreMsg` is a oneof: `Ready` \| `Event` \| `Shutdown`.

Every unary call **must** carry `x-vibecare-plugin-id` metadata, or core returns `Unauthenticated`.

### Client ↔ core — `proto/client/v1/client.proto`

Two RPCs, frozen: `Plugins` (roster stream) and `Intents` (alert stream).

### HTTP conventions

| Path | Serves |
|---|---|
| `GET /` | HTML UI |
| `/api/*` | JSON — the real interface |
| `GET /health` | liveness |

Everything else is yours (`/preview.mjpeg`, assets). Two hard rules for plugin HTML:

- **All URLs must be relative.** The plugin is mounted at `/p/<id>/` and must not know it.
- **No `localStorage`, `sessionStorage`, or cookies.** All plugins share one web origin in v1;
  depending on browser storage is what would make origin isolation expensive to add later.

Requests are authenticated by core before they reach the plugin. Plugins write **zero** auth code.

## Storage

Plugin state lives in `~/.vibecare/data/<id>/`, created `0700` before spawn and passed as
`VIBECARE_DATA_DIR`. There are **no storage RPCs** — the plugin owns everything inside it and picks
its own format.

> This inverts v1, where plugins were stateless and stored data through core.

Cross-plugin communication is **bus topics only, never the filesystem**.

## Bus and topics

Topic naming is `<domain>.<noun>.v<n>`. Payloads evolve by bumping the version in the topic name.
Publishing a topic not declared in the manifest is a logged error and a dropped message — manifests
stay honest.

Events are ephemeral: no persistence, no replay, no delivery guarantee. A slow subscriber is dropped
rather than buffered without bound.

### Demand refcounting

A provider must idle — camera closed, LED off — when nothing subscribes. Core refcounts subscribers
per topic and delivers `_core.demand.v1` to the **publishing** plugin.

Two things routinely surprise people:

- A plugin with an **empty `publishes` list never receives demand events at all**, regardless of
  what it subscribes to. Declaring the reserved topic in `subscribes` does nothing.
- Demand is authoritative **state, not a delta**. Transitions occurring while your stream is down are
  dropped, never replayed. Overwrite local state from every event; expect a full burst on reconnect.

**Zero subscribers → close the capture session** applies only to a topic whose payload *is* the
capture output. Do not gate a plugin's own function on demand for a topic nobody subscribes to — the
count is structurally zero and the plugin becomes a no-op.

## Alerts

`Alert()` → core → `Intents` → every connected client → native panel.

Alerts are the one UI path that is **not** HTML, because they must render with no window open and
with the plugin's webview never loaded. They are transient: a client that connects after an alert
fired does not see it.

Levels are `"info"` and `"warn"` — nothing else exists, and anything unrecognised renders as info.

`AlertAction.url` is plugin-relative; pressing a button navigates the client to `/p/<id>/<url>`,
reusing the proxy rather than inventing a callback channel. **Action endpoints should accept both GET
and POST**, since a client following an action URL issues a GET.

### Alert appearance

An alert may carry an optional `appearance` blob. The kernel forwards it opaquely and never looks
inside — an alert's appearance is product semantics, and the kernel has none.

That does **not** make the format yours. `appearance` is **the shell's alert vocabulary**, not a
plugin-defined one: the client decodes a shape it already owns, and a plugin that invents its own
gets the plain banner. What you gain is not freedom of schema — it is that speaking this one needs
**no client release and no per-plugin code in the client**.

The blob is a JSON object encoded as a string. Every field is optional. The authoritative definition
is `clients/macos-swift/VibeCare/VibeCare/Models/PluginAlertAppearance.swift`.

| key | type | notes |
|---|---|---|
| `bundledIconId` | string | id in the client's built-in icon catalog |
| `svgPath` | string | absolute (`http(s)://`, `file://`, `/abs/path`) or **plugin-relative**, resolved against `/p/<id>/` |
| `svgWidth` / `svgHeight` | number | illustration size in points |
| `position` | string | `center` \| `topLeft` \| `topRight` \| `bottomLeft` \| `bottomRight` |
| `width` / `height` | number | alert size; `height` is a floor, not a cap — a button row grows it |
| `moveable` | bool | user can drag the alert |
| `autoDismissAfter` | number | seconds |
| `screenBlurEnabled` | bool | blur the screen behind the alert |
| `screenBlurIntensity` | string | `light` \| `medium` \| `heavy` |
| `title` / `message` | string | accepted but **not applied** — the alert's own `title`/`body` always win |

Anything omitted falls back to the shell's defaults: centered, 450×220, a 220×150 illustration,
moveable, dismissed after 20s, no blur. `title`/`message` are tolerated so a plugin can forward its
stored preferences verbatim; they are dropped, because the sender already applied its wording and
may have computed something at fire time (a running count) that a stored preference cannot contain.

Five behaviours routinely surprise people:

- **Absent is not zero.** An omitted field means "the client's default"; a present field means that
  exact value. `"autoDismissAfter": 0` asks for an alert that dismisses immediately, not for 20s.
- **A blob matching none of these keys is rejected outright** and the alert renders as the plain
  banner. That is deliberate: since every field is optional, without the check any unrelated JSON —
  another schema entirely, or `{}` — would "decode" into an all-nil appearance, which the renderer
  would read as *restyle this alert with nothing*. A non-object, invalid JSON and `""` are rejected
  the same way (though `""` is still a *present* appearance on the wire — presence and emptiness are
  distinct).
- **Lenient per field, strict overall.** One bad value — `"width": "wide"`, a `position` this client
  has never heard of — costs that field only; the rest of the appearance still applies. Unknown
  extra keys are ignored, but they do not count towards "did we understand any of this?".
- **A relative `svgPath` that fails to load downgrades the whole alert to the plain banner**, rather
  than rendering a rich alert with a hole where the picture should be — the banner still draws the
  action buttons, and losing a "Turn off" button is a functional loss where losing an illustration
  is a cosmetic one. A relative path is fetched through the proxy with the shell's session cookie
  (2s timeout, cached per URL); an absolute one is loaded directly and bypasses the proxy entirely.
  An appearance that never asked for an illustration is *not* this case and still renders rich.
- **A rejected appearance never costs the interrupt.** A `warn` alert's sound and screen flash fire
  before any renderer is chosen, so a blob the client cannot read degrades the look, not the nudge.

Today the illustration is resolved from `svgPath` only; `bundledIconId` is decoded and carried but
not turned into an image on the alert path. Ship the SVG with your plugin and point `svgPath` at it
relatively — a plugin cannot know the port core assigned it, so a relative path is the only thing it
can honestly send.

**Sending one.** Both SDKs carry a typed builder for this exact shape — `vc.Appearance` (Go,
`backend/pkg/vc`) and `VCAlertAppearance` (Swift, `sdk/swift/VCPluginSDK`) — so you
never hand-roll the string:

```go
style := vc.NewAppearance().
	WithSVG("icons/nose-picking.svg", 220, 150).
	WithPosition(vc.PositionCenter).
	WithSize(450, 220).
	WithMoveable(true).
	WithAutoDismissAfter(20 * time.Second).
	WithScreenBlur(vc.BlurLight)

h.Alert(vc.Alert{
	Title:   "Nose-picking",
	Body:    "Ease off — 6th nudge today",
	Level:   "warn",
	Actions: []vc.AlertAction{{Label: "Snooze 10 min", URL: "api/snooze?minutes=10"}},
	Style:   style,
})
```

`Alert.Style` is the typed field; the older raw `Alert.Appearance *string` still works and is
still what goes on the wire, but when both are set `Style` wins and the raw one is not merged.
Every `Appearance` field is a pointer so that *unset* and *set to zero* stay distinguishable —
use the `With…` builders, or `vc.Ptr` for struct-literal construction.

```swift
let style = VCAlertAppearance(
    svgPath: "icons/nose-picking.svg", svgWidth: 220, svgHeight: 150,
    position: .center, width: 450, height: 220, moveable: true,
    autoDismissAfter: 20, screenBlurEnabled: true, screenBlurIntensity: .light
)
try await host.alert(VCAlert(
    title: "Nose-picking",
    body: "Ease off — 6th nudge today",
    level: "warn",
    actions: [VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10")],
    appearance: style
))
```

The wire format is the thing of record; the builders are only the convenient path to it. Both of
the above put the same keys and values on `AlertReq.appearance`:

```json
{"autoDismissAfter":20,"height":220,"moveable":true,"position":"center","screenBlurEnabled":true,"screenBlurIntensity":"light","svgHeight":150,"svgPath":"icons/nose-picking.svg","svgWidth":220,"width":450}
```

Key *order* is not part of the contract and differs by language — the Swift SDK sorts keys, Go
emits them in declaration order. The client decodes by key, so both are equally valid; only a
test that compares whole strings needs to care, and each language pins its own.

Neither side can import the other's type, so those bytes are pinned as literals in both
`plugins/vibecheck/Tests/VibeCheckKitTests/HostSinkTests.swift` and
`clients/macos-swift/VibeCare/VibeCareTests/PluginAlertAppearanceTests.swift`. That pair **is** the
cross-language contract: rename or retype a field on either side and exactly one of them goes red.
Without them, drift shows up only as the user silently getting a plain banner again, every test
still green. `plugins/vibecheck/Sources/VibeCheckKit/HostSink.swift` (`fired`) is the live
example — it sends an appearance on every detection alert, not only customized ones, so the
out-of-the-box alert is the good-looking one rather than a hidden setting.

## Rules that bite

Every item here caused a real defect.

**Never exit the process.** Core charges any unrequested exit as a failed start; five park the plugin
in `StateFailed` until a manual dashboard restart. A ready-timeout, a rejected registration, a denied
camera — all degrade in-process and retry. The only sanctioned exit is a malformed spawn environment,
where there is no core connection to degrade against.

**A clean end of the Register stream is not an error.** Core returns `nil` when a non-superseded
cancel closes the subscriber channel. In Go that surfaces as `io.EOF`; in grpc-swift the response
sequence simply finishes with nothing thrown. A loop shaped `do { for try await … } catch { retry }`
falls out and never reconnects again.

**Serve persistent HTTP/1.1.** The health prober reuses a keep-alive connection. A close-per-response
server fails probes intermittently, which demotes the plugin to `degraded` and makes the proxy serve
a 503 page.

**Put a deadline on `Publish` and `Alert`.** Neither has one by default; both can block indefinitely
against a wedged core.

**SIGTERM is the only guaranteed shutdown notice.** `BroadcastShutdown` iterates live streams only,
so a plugin mid-reconnect never receives `CoreMsg.shutdown`.

**`/health`'s `detail` only surfaces when `degraded`.** Core force-clears detail on any transition to
`up`, so `{"status":"ok","detail":"…"}` silently discards the text.

**`RegisterReq.id` must equal `VIBECARE_PLUGIN_ID`.** Core does not cross-check it against the call
metadata, so a wrong id silently hijacks another plugin's proxy target and bus subscription.

### macOS specifics

**Camera permission is keyed to the spawning process, not the plugin.** The TCC grant belongs to
whatever spawned the binary; the child's embedded `__info_plist` only supplies the prompt text. So a
camera-touching plugin needs **no app bundle and no Developer ID** — but it must embed an
`Info.plist` carrying `NSCameraUsageDescription` via
`-sectcreate __TEXT __info_plist`, and **that section is inert until a signature seals it**
(`codesign -f -s -`, ad-hoc, no certificate required). Because the grant follows the spawner, it
survives plugin rebuilds.

**Never leave an `Info.plist` beside an executable named after its own directory.** That combination
*is* a flat bundle to `codesign`, which then demands a `_CodeSignature/` a plain copy never creates —
and AMFI SIGKILLs the binary at spawn while `codesign --verify` still calls the file valid. Stage
build output into a clean `dist/` directory.

**Install by rename, not by copy.** `cp` truncates and rewrites the same inode; if a running core has
that inode mapped, macOS refuses to exec it again. The signature is fine — the kernel's cached
validation for that inode is not. Write a new file and `mv` it into place.

**The built-in camera is never auto-mirrored.** It reports `position = .unspecified`, so
`automaticallyAdjustsVideoMirroring` never engages on either the preview or the data-output
connection. Read `connection.isVideoMirrored` per frame; never infer it.

**Unix socket paths are capped at 104 bytes** (`sockaddr_un`). `t.TempDir()` blows past it. Put test
sockets under `os.MkdirTemp("/tmp", …)`.

## Writing a plugin

Use `plugins/todo/` (Go) or `plugins/vibecheck/` (Swift) as the structural template. Minimum:

```
plugins/<id>/
  manifest.yaml
  <source>
  dist/<binary>        # staged build output — see the flat-bundle rule above
```

The Go SDK is `backend/pkg/vc`; `vc.Connect()` is the whole entry point. The Swift SDK is
`sdk/swift/VCPluginSDK`, a standalone SwiftPM package that every Swift plugin here takes as a
local path dependency — `VCHost.connect()` is its entry point. It used to live inside `vibecheck`;
the second copy that grew alongside it is how two disagreeing `Package.resolved` files appeared in
this tree, which is why it is shared now. `plugins/todo/` (Go) and `plugins/vibecheck/` (Swift) are
the references if you write another one.

Build and install:

```bash
just build-plugins      # builds every plugin into its own dist/
just install-plugins    # copies them to ~/.vibecare/plugins-v2/<id>/
just run                # runs core against the repo's plugins/ directory
just dev-ui             # same, with plugin UI served from disk + live reload
```

> `just run` passes `--plugins-dir ../plugins`; a default-configured core reads
> `~/.vibecare/plugins-v2/`. A plugin rebuilt but not installed will not reach a core started any
> other way, and nothing reports the mismatch.

Core's dashboard is at `<base_url>/_core/status`; get `base_url` from the `Plugin kernel ready
origin=` log line and the token from `~/.vibecare/session`.

## Testing a plugin

Two tiers, as `plugins/todo/` and `plugins/vibecheck/` both do:

1. **Unit tests** for pure logic — stores, state machines, coordinate math.
2. **One end-to-end test against a real in-process kernel** (`kernel.New` + `kernel.Start`), asserting
   the drop-in loop: reachable through `/p/<id>/`, 401 without the session cookie, `state == "up"` in
   `/_core/api/plugins`, and **on-disk state read directly from the file** rather than round-tripped
   through the process that wrote it.

Prove a guard can fail before trusting it. Temporarily break the thing, watch the test go red, restore.
Several guards in this codebase's history could not fail and nobody knew — a keep-alive assertion
defeated by client-side connection pooling, and a UI check that passed equally against the placeholder
page it replaced.

## Deliberately deferred

Signing and a third-party registry · sandboxing and permission enforcement · storage quotas ·
hot-add without a core restart · per-plugin origin isolation · event-log persistence and replay ·
native views as a per-plugin optimisation.

Each is addable without changing the contracts above.
