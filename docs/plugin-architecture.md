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

An alert may carry an optional `appearance` blob. The kernel forwards it opaquely and never looks
inside — an alert's appearance is product semantics, and the kernel has none.

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

The Go SDK is `backend/pkg/vc`; `vc.Connect()` is the whole entry point. There is no shared Swift
SDK — `vibecheck` carries its own under `Sources/VCPluginSDK/`, which is the reference if you write
another Swift plugin.

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
