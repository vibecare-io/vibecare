# Plugin Architecture v2 — Self-Contained Plugins with Plugin-Served UI

**Status:** design approved, nothing built.
**Date:** 2026-08-13
**Supersedes:** [`docs/plugin-revision-discussion.md`](../../plugin-revision-discussion.md)
**Reverses:** decision #6 in [`docs/plugin-system-decisions.md`](../../plugin-system-decisions.md) (server-driven declarative UI rendered natively by the shell)
**Stack:** Go core daemon · gRPC over unix socket · HTTP over loopback · Swift macOS client

---

## 1. Why this revision exists

The previous design (`plugin-revision-discussion.md`) optimized for native UX and cross-client
portability. Two product decisions changed the optimization target:

1. **Plugins must be droppable, independently developed binaries.** They live in `plugins/<id>/`
   in this repo for now, but each must build, ship, and restart without rebuilding core or
   releasing the client. Possibly in languages other than Go.
2. **Plugin UI is served by the plugin** as a webview/HTTP surface. Configuration screens, and
   genuinely visual surfaces like the camera preview, come from the plugin itself.

A third decision removes most of the remaining machinery — **provisionally**:

3. **Crash resilience is not required in v1.** If a plugin is down, the client shows an error
   page. This is a deliberate simplification we expect to revisit, not a permanent stance.

Trust is likewise **total for now** — all plugins are first-party and live in this repo. Signing,
sandboxing, permission enforcement, and a registry are out of scope for v1 and are expected to
return once plugins are authored outside this repo.

Because both are expected to change, *Revisiting decision 3* at the end of this section records
what revisiting them costs, and which v1 choices are cheap to reverse versus expensive.

### What decision 1 killed

Plugins compiled into the core binary as Go packages (§1.7 of the prior doc). Linked-in packages
cannot be rebuilt or restarted independently, which is the entire ask. **Plugins are subprocesses
from day one.** First-party-only trust means this costs nothing extra: the expensive part of the
subprocess model (signing, sandbox, permission enforcement) stays deferred.

### What decision 3 killed

"Renders while the plugin is asleep or crashed" was the sole justification for the retained state
store. With it goes: the `(plugin_id, rev, blob)` table, the core-owned rev counter, hash-dedupe,
fan-out coalescing, replay-on-connect, `PushState`, per-plugin state protos, and the
`StateUpdate` stream carrying `google.protobuf.Any`.

### What decision 2 killed

Per-plugin native Swift views, the generic `Card`/`ListPanel`/`SettingsForm` primitives, and the
`config_schema` → native settings form mechanism. Also the whole `ViewDescriptor`/`Node`
declarative UI vocabulary in the current `proto/vibecare_plugin.proto`.

### Revisiting decision 3 — what it costs later

**Trust (signing, sandboxing, permissions, registry) — cheap to add; contracts unaffected.**
Nothing in §5 or §6 changes. The supervisor gains signature verification before spawn, the
manifest gains a permissions block, and the bus enforces publish/subscribe ACLs declared there.
No proto is touched.

Two v1 choices are **expensive to reverse**, and are the ones to watch:

- **Shared web origin (§7.5).** Tolerable between first-party plugins; a genuine vulnerability
  between untrusted ones, since any plugin's JavaScript can drive any other plugin's API. Origin
  isolation stops being optional the day a plugin is authored outside this repo. This is why
  §7.5 forbids plugins from depending on `localStorage` — that restraint is what keeps the
  switch cheap.
- **Unenforced storage boundaries (§9).** A plugin process can read every other plugin's data
  dir. Enforcement needs either OS-level containment or core-hosted storage returning, and the
  latter re-adds the KV RPCs that D8 removed.

Beyond those, an untrusted plugin is still an unrestricted user process. Real sandboxing is a
separate design problem, not a parameter of this one.

**Crash resilience — partially addable, and capped by D4.**
Plugin-served UI means that when the plugin is down there is no UI to serve, so full
render-while-down is unreachable without reversing D4. What *is* reachable, in increasing cost:

1. **Shell-level status.** Plugins publish a small retained topic; the roster and menu bar keep
   showing last-known facts ("3 today") while the plugin is down. This also restores the menubar
   badge listed as a loss in §3. No contract change — it is a retention flag on a topic.
2. **Stale UI from the proxy.** Core caches each plugin's last-served assets and serves them
   read-only when the plugin is down. The proxy already sits in the path, so this is contained to
   `proxy.go`. Interactions still fail; the page renders.
3. **Full render-while-down.** Requires the client to hold plugin UI — i.e. reversing D4. Out of
   scope indefinitely.

Options 1 and 2 are both compatible with everything in this spec. That compatibility is what
makes deferring crash resilience safe rather than merely convenient.

---

## 2. Decisions

| # | Decision |
|---|---|
| D1 | A plugin is a **subprocess** discovered from `plugins/<id>/manifest.yaml`. Core scans, spawns, supervises. |
| D2 | The plugin is **always the gRPC client, never a gRPC server.** Core never calls into a plugin over gRPC. |
| D3 | Plugin↔core is **three RPCs**. Client↔core is **two RPCs**. |
| D4 | Plugin UI is **HTTP served by the plugin**, embedded by clients as a webview. |
| D5 | Core is a **reverse proxy** at `<base_url>/p/<plugin-id>/*`. Plugins write no auth code. |
| D6 | Plugins **and core** bind `127.0.0.1:0` — the kernel picks every port. No port configuration, ever, and nothing to collide with. |
| D7 | **Alerts stay native.** They must work with no window open, so they are the one UI path that is not HTML. |
| D8 | Plugins **own their storage**. Core assigns a data dir; the plugin picks its own store. No KV RPCs. |
| D9 | The **bus survives unchanged.** It is the one mechanism with no alternative — `vision → vibecheck` and `activitywatch → vibecheck` are not expressible any other way. |
| D10 | Core contains **zero product semantics**. No file in `kernel/` contains "posture", "nailbiting", or "todo". |
| D11 | Health is **two independent signals** — stream connected (control plane) and `GET /health` (data plane) — because they fail independently. Health rides on HTTP, not a fourth RPC, so D2 survives. |
| D12 | Core serves a **status dashboard** at `/_core/status` with per-plugin stats and a restart button. It lives in core, not a plugin, so it still works when the plugin system is unhealthy. |

---

## 3. Non-goals and accepted losses

These are decisions, not oversights. Each is a deliberate trade for plugin independence.

- **No TUI client in v1 — but not traded away.** Plugins serve JSON at `/api/*` beside their HTML
  (§7.2), so a TUI can render from the same surface the webview uses, over the same proxy and
  token. Building that client is deferred; the ability to build it is preserved by convention
  (§6.2).
- **No menubar badge or live plugin status in the shell.** Nothing pushes facts to the client
  anymore, so "3 detections today" has no path to the menu bar. Re-addable later as a retained
  topic without changing any contract here (see *Revisiting decision 3*, §1).
- **No render-while-down in v1.** Plugin down → error page. Partially addable later; full
  render-while-down is capped by D4 (see *Revisiting decision 3*, §1).
- **"Explicitly not Electron" now applies only to the shell and alerts,** not to plugin screens.
- **No core-managed backup or storage quota**, since plugins own their files.
- **All plugins share one web origin** (see §7.5 for the consequence).

---

## 4. Plugin anatomy and discovery

```
plugins/vibecheck/
  manifest.yaml         ← core reads this BEFORE spawning
  vibecheck             ← the binary
  ui/                   ← static files, or embedded in the binary
```

```yaml
id: vibecheck
name: VibeCheck
icon: eye
exec: ./vibecheck
subscribes: [sensor.landmarks.v1, activity.afk.v1]
publishes:  [vibecheck.behavior_detected.v1]
ui: webview              # or: none — headless plugin, no tab in the client
```

Discovery is file-based, which is what makes plugins droppable: core scans
`plugins/*/manifest.yaml` at startup. Adding a plugin requires no registration in core, no code
change, and no rebuild of anything but the plugin.

`id` is the routing key, the data-dir name, and the topic namespace prefix. It must match
`^[a-z][a-z0-9-]*$`. Duplicate ids are a startup error naming both paths.

**Every plugin must work correctly with all others disabled.** Cross-plugin behavior is always an
enhancement gated on presence, never a requirement. A plugin that subscribes to a topic nobody
publishes simply receives nothing.

---

## 5. Plugin ↔ core contract

`proto/plugin/v1/plugin.proto`:

```proto
service PluginHost {                                  // core serves; plugin only ever calls
  rpc Register(RegisterReq) returns (stream CoreMsg);  // handshake + events + shutdown + liveness
  rpc Publish(Event) returns (Empty);
  rpc Alert(AlertReq) returns (Empty);
}

message RegisterReq { string id = 1; uint32 http_port = 2; }

message CoreMsg {
  oneof k {
    Ready    ready    = 1;
    Event    event    = 2;
    Shutdown shutdown = 3;
  }
}

message Event    { string topic = 1; bytes payload = 2; google.protobuf.Timestamp ts = 3; }
message Ready    {}
message Shutdown { string reason = 1; }

message AlertReq {
  string title = 1;
  string body  = 2;
  string level = 3;                  // info | warn
  repeated AlertAction actions = 4;  // rendered as buttons
}
message AlertAction { string label = 1; string url = 2; }  // url is plugin-relative
```

`AlertReq`/`AlertAction` are defined here and imported by `proto/client/v1` rather than
duplicated — an alert crosses both contracts unchanged, and two definitions would drift.

**One open stream does three jobs:** confirms registration, delivers subscribed events, and
signals graceful shutdown. Health is a separate, two-signal concern (§5.2) — the stream alone
cannot distinguish a healthy plugin from one whose HTTP server has hung.

Transport is gRPC over a unix socket at `~/.vibecare/core.sock` (mode 0600). The socket path,
plugin id, and data dir arrive as environment variables at spawn (§8).

Subscriptions come from the manifest, not from an RPC. Core knows what to deliver before the
plugin connects.

### 5.1 Why the plugin is never a server

A plugin author in any language writes an HTTP server — trivial in every language — and three
outbound gRPC calls. No generated service stubs to implement, no bidi multiplexing, no reflection.
This makes the "~50 lines of gRPC for a provider plugin" claim literally true and keeps
non-Go plugins genuinely cheap.

Health deliberately rides on HTTP (§5.2) rather than a fourth RPC, so this property survives:
a plugin adds one route, not another gRPC method.

### 5.2 Liveness, health, and retries

Two independent signals, because they fail independently:

| Signal | Means | Detects |
|---|---|---|
| **Register stream connected** | control plane alive | process died, crashed, or was killed |
| **`GET /health` → 200** | data plane responsive | HTTP hung, deadlocked, or wedged while the process lives |

`GET /health` returns 200 with an optional JSON body (§5.3). Core probes every 10s with a 2s
timeout. The SDK registers a default handler, so most authors write nothing; a plugin that wants
to report degraded state overrides it.

**Plugin state machine:**

```
 starting ──register──► up ──3 failed probes──► degraded ──3 more──► down
     │                   ▲                          │                 │
     │                   └────── probe recovers ────┘                 │
     └── 10s no register ──────────────────────────────────► failed ◄─┘
                                                    (5 consecutive bad starts)
```

`degraded` is deliberately visible rather than internal: it is the state where the tab still
loads but is misbehaving, and hiding it makes that indistinguishable from a slow plugin.
Requiring three consecutive failures before any transition prevents flapping on one slow probe.

**Retries, in three places:**

1. **Plugin reconnects to core.** If the Register stream drops, the plugin does **not** exit — it
   keeps serving HTTP and re-dials with backoff (1s, 2s, 4s, capped at 30s). This is what makes a
   core restart survivable: without it, restarting core would kill every running plugin. The SDK
   handles it; plugin authors write nothing.
2. **Core restarts the process** on exit, per §8's backoff.
3. **Clients retry the view.** The roster stream already pushes state changes, so when a plugin
   returns to `up` the client reloads that webview automatically rather than leaving the user on
   a stale error page.

### 5.3 Stats

Core tracks per plugin, in memory: state, pid, uptime, restart count, last exit reason, last
probe latency, events published, events delivered, and last event timestamp. These need no plugin
cooperation — core sits on both the stream and the proxy, so it already sees everything.

A plugin may optionally enrich this by returning JSON from `/health`:

```json
{ "status": "ok", "detail": "camera: FaceTime HD", "since": "2026-08-13T09:12:00Z" }
```

`status` is `ok` | `degraded`, and a plugin reporting `degraded` moves to that state immediately
rather than waiting for probes to fail. `detail` is free text shown in the dashboard (§7.5).

---

## 6. Client ↔ core contract

`proto/client/v1/client.proto`:

```proto
service Vibecare {
  rpc Plugins(Empty) returns (stream PluginList);  // roster; re-sent on any change
  rpc Intents(Empty) returns (stream UIIntent);    // alerts
}

message PluginList { repeated PluginInfo plugins = 1; string base_url = 2; string token = 3; }
message PluginInfo {
  string id    = 1;
  string name  = 2;
  string icon  = 3;
  string path  = 4;    // "/p/vibecheck/" — stable across plugin restarts
  State  state = 5;
  string detail = 6;   // exit reason when down/failed; /health detail when degraded
}
enum State { STARTING = 0; UP = 1; DEGRADED = 2; DOWN = 3; FAILED = 4; }
message UIIntent { oneof k { Alert alert = 1; } }
message Alert {
  string plugin = 1; string title = 2; string body = 3; string level = 4;
  repeated AlertAction actions = 5;
}
```

`Act` from the previous design is gone. Once the webview owns the screen, the client already
talks to the plugin over HTTP, so user input posts straight to the plugin; routing it through core
would be ceremony with no benefit.

### 6.1 The client coupling rule, restated

The previous design's discipline — *"no plugin-specific endpoint exposed directly to clients"* —
was written for the native-view world and is broken by D4 the moment a WKWebView loads a plugin's
HTTP. Its intent survives and is restated:

> **Clients contain no plugin-specific code.** A client knows only "a URL", never a schema.

This is the coupling that actually matters. It is what keeps the client contract frozen at two
RPCs while plugins are added indefinitely.

### 6.2 Non-webview clients

A client that cannot embed a webview is not locked out. Plugins serve JSON at `/api/*` (§7.2)
through the same proxy and the same token, so a TUI reaches every plugin's data over plain HTTP
with no core involvement and no plugin change.

What such a client renders from that JSON is a decision deferred to whenever one is built:

- **Per-plugin adapters** — the TUI ships a renderer for each plugin it knows. Simple, and it
  relaxes §6.1 for that client only. A plugin with no adapter degrades to "open in browser".
- **A conventional descriptor** — plugins optionally expose `GET /api/view` returning a generic
  item/toggle/field list any client can render blindly. This resurrects the idea behind the
  deleted `ViewDescriptor`, but plugin-authored, optional, and over HTTP — so it never enters the
  core contract or the proto surface.

Neither is a v1 decision. What v1 must preserve is the `/api/*` convention that makes both
reachable, which costs nothing today.

---

## 7. HTTP surface, proxy, and auth

### 7.1 Core's HTTP

Core binds `127.0.0.1:0` — loopback only, kernel-assigned port — and reports the resulting origin
to clients as `PluginList.base_url`. Nothing depends on a fixed port, so there is nothing to
collide with and nothing to configure. Core reverse-proxies:

```
http://127.0.0.1:<core>/p/<plugin-id>/<path>   →   http://127.0.0.1:<plugin>/<path>
```

The proxy is `httputil.ReverseProxy` with **`FlushInterval = -1`**. Without this, response
buffering hangs MJPEG preview streams and SSE. This is not optional.

When a plugin is down, core serves a generic error page at its path rather than proxying.

### 7.2 The plugin's HTTP

Largely the plugin author's design, with **three conventions**:

| Path | Serves | Consumed by |
|---|---|---|
| `GET /` | HTML UI | webview clients (macOS) |
| `/api/*` | JSON | every other client — TUI, CLI, scripts |
| `GET /health` | liveness, optional detail JSON | core's probe (§5.2); SDK supplies a default |

Everything else — `/preview.mjpeg`, static assets — is up to the plugin.

The split is load-bearing, not stylistic. A plugin's HTML is one *renderer* of its API, not the
plugin's only interface. Keeping the JSON surface honest and complete is what lets a non-webview
client exist later without core changing, without the plugin changing, and without reversing D4
(§6.2). Plugin authors should treat `/api/*` as the real interface and `/` as its first consumer.

### 7.3 Auth

Core mints one 32-byte random session token at startup, writes it to `~/.vibecare/session`
(mode 0600), and hands it to clients in `PluginList`. The client appends it to the initial
webview load as `?vc=<token>`; core validates, sets an `HttpOnly; SameSite=Lax` cookie scoped to
`/p/`, and validates that cookie on every proxied request. Failures return 401 with a generic
page.

**Plugins write no auth code at all.** Authentication happens once, in one place, in core.

### 7.4 Reserved paths and the status dashboard

`/_core/*` is reserved for core itself and is never proxied. Plugin ids cannot collide with it:
§4's `^[a-z][a-z0-9-]*$` rejects a leading underscore.

Core serves its own surface following the same HTML/JSON split it asks of plugins (§7.2):

| Path | Serves |
|---|---|
| `GET /_core/status` | the dashboard, HTML |
| `GET /_core/api/plugins` | the same data, JSON |
| `POST /_core/api/plugins/<id>/restart` | manual restart, including out of `failed` |

The dashboard lists every discovered plugin with its state, uptime, restart count, last exit
reason, probe latency, event counts, and any `/health` detail (§5.3) — plus a restart button. It
is how a `failed` plugin becomes visible and recoverable without reading logs or restarting core.

The macOS client surfaces it as a built-in tab, rendered as a webview like any other, pointed at
core's own path instead of a plugin's. No special-case client code.

This lives in core rather than in a `status` plugin because a dashboard that goes dark whenever
the plugin system is unhealthy is worthless precisely when it is needed. It stays consistent with
D10: it reports on plugins generically and names none of them.

### 7.5 The shared-origin caveat

Every plugin is served from the same origin (core's loopback address). Consequences: plugins share
`localStorage`, share a cookie jar, and one plugin's JavaScript can `fetch` another plugin's
endpoints. At first-party scale this is acceptable and we ship it.

If origin isolation is ever needed, the fix is a subdomain per plugin
(`vibecheck.localhost:<core>`) — but macOS's resolver does not reliably resolve arbitrary
`*.localhost`, so that must be verified before being relied on. Retrofitting isolation after
plugins depend on shared browser storage is painful, so plugins **should not** use `localStorage`
for anything they cannot lose. Plugin state belongs in the plugin's own data dir (§9).

---

## 8. Supervisor and lifecycle

**Spawn.** Working directory is the plugin's own directory. Environment:

```
VIBECARE_SOCKET=/Users/<u>/.vibecare/core.sock
VIBECARE_PLUGIN_ID=vibecheck
VIBECARE_DATA_DIR=/Users/<u>/.vibecare/data/vibecheck
```

**Registration timeout.** A plugin that has not called `Register` within 10s is killed and
treated as a failed start.

**Restart policy.** Exponential backoff on exit: 1s, 2s, 4s, 8s, 16s, 32s, capped at 60s. The
backoff resets once the plugin has stayed `up` for 60s. After 5 consecutive failed starts the
plugin is marked `failed` and is not restarted automatically; it appears in the roster and the
dashboard with the exit reason in `PluginInfo.detail`, and is recoverable by the restart button
(§7.4).

A `degraded` plugin (§5.2) is **not** restarted automatically. Its process is alive and may hold
unflushed state, so killing it is a decision for the user via the dashboard rather than something
core does on a timer.

**Core restart does not kill plugins.** Plugins are children of core, so a core exit does end
them — but a plugin whose *stream* drops while its process survives reconnects rather than exiting
(§5.2). This matters for development: `vibecare dev` restarting core must not require restarting
every plugin.

**Shutdown.** Core sends `CoreMsg.Shutdown` on the stream, then `SIGTERM`, then `SIGKILL` after
5s. Plugins should close their HTTP listener and flush storage on `Shutdown`.

**Roster updates.** Any change to any plugin's `state` re-sends the whole `PluginList` to every
connected client. The roster is small and changes rarely; there is no need for deltas.

---

## 9. Storage

`Register` implies a data dir; core creates `~/.vibecare/data/<plugin-id>/` before spawning and
passes it as `VIBECARE_DATA_DIR`. The plugin owns everything inside it and picks its own store —
sqlite, JSON, whatever fits.

There are **no storage RPCs**. Uninstall is deleting one directory. Corruption is contained to one
plugin.

The previous design's namespacing guarantee ("a plugin cannot express 'read another plugin's
data'") becomes convention rather than enforcement. That is acceptable at first-party scale and is
re-addable later without touching any contract here.

**The filesystem is never how plugins share data.** Cross-plugin communication is bus topics only.

---

## 10. Bus and topics

Core's bus is topic → subscriber channels, in-memory, fire-and-forget. Events are ephemeral:
no persistence, no replay, no delivery guarantee. A slow subscriber is dropped rather than
buffered without bound.

**Topic naming:** `<domain>.<noun>.v<n>`, e.g. `sensor.landmarks.v1`,
`vibecheck.behavior_detected.v1`, `activity.afk.v1`. Payloads evolve by bumping the version in the
topic name; a v2 publisher and a v1 subscriber simply do not interact.

Publishing a topic not declared in the manifest is a logged error and a dropped message —
manifests stay honest.

The `_core.` prefix is **reserved** for topics core itself originates (§10.2). These are delivered
to the relevant plugin without being declared in its manifest, and a plugin may not publish them.

### 10.1 Sensor contract — `proto/topics/v1/landmarks.proto`

Load-bearing, because two independent providers feed it and silent drift means "vibecheck fires
constantly on Linux."

```proto
message LandmarkFrame {
  google.protobuf.Timestamp ts = 1;
  uint64 seq       = 2;          // monotonic per provider; gaps = dropped frames
  string device_id = 3;          // which camera, when several exist
  repeated Hand hands = 4;       // 0..2
  Face face = 5;                 // optional
  float fps_hint = 6;
}
message Hand { repeated Point joints = 1;   // exactly 21, MediaPipe topology order
               Handedness handedness = 2; float confidence = 3; }
message Face { Rect bounds = 1; Point nose_tip = 2; Point mouth_center = 3;
               Point chin = 4; repeated Point scalp_line = 5; float confidence = 6; }
message Point { float x = 1; float y = 2; }   // normalized 0..1
```

**Coordinate convention — mandatory, and the single most common source of silent breakage:**

> All coordinates are in **viewer space**: the frame as the user sees themselves in a mirrored
> selfie preview. Origin is top-left, `x` increases right, `y` increases down, both normalized
> `0..1`. Providers apply any mirroring **before** publishing. Consumers never mirror.

The macOS front camera buffer is already mirrored by `AVCaptureVideoPreviewLayer`'s default
`automaticallyAdjustsVideoMirroring`, so `vision-macos` publishes as-is; a provider whose source
is not mirrored must flip `x` itself. This is stated as an invariant rather than a proto field
because a field invites consumers to branch on it, which is exactly the drift we are preventing.

Confidence is `0.0..1.0`. An empty `LandmarkFrame` (no hands, no face) is a valid published
message meaning "nothing detected"; *no message* means the provider is idle or down. These are
different and consumers must treat them differently.

**Conformance suite:** one recorded video → each provider → assert **episode-level** agreement
(same behavior detected, onset within ±250ms). Landmark-level numeric agreement is not a valid
target — `VNDetectHumanHandPose` and MediaPipe use different models and will not agree.

### 10.2 Demand-driven capture

A provider must idle — camera closed, LED off — when nothing subscribes to its topic. Core
refcounts subscribers per topic and delivers `CoreMsg.Event` on topic `_core.demand.v1` with the
current count to the publishing plugin. Zero subscribers → the provider closes its capture
session. This is a privacy property enforced by mechanism, not policy, and it is the reason
demand refcounting is in core rather than in each provider.

---

## 11. Alerts

`Alert()` → core → `Intents` stream → every connected client → native NSPanel.

Alerts are the one UI path that is not HTML, because they must render with no window open and
with the plugin's webview never loaded. They are transient and never retained: a client that
connects after an alert fired does not see it.

`AlertAction.url` is plugin-relative. A button press navigates the client to
`/p/<plugin>/<url>` — reusing the proxy rather than inventing a callback channel.

---

## 12. Core layout

```
backend/kernel/
  supervisor.go   spawn · env · restart-with-backoff · SIGTERM/SIGKILL
  registry.go     manifest scan · id → {port, state, manifest} · roster fan-out
  health.go       /health probes · state machine · per-plugin stats
  bus.go          topic → subscriber channels · fan-out · demand refcount
  proxy.go        /p/<id>/* → 127.0.0.1:<port>   (ReverseProxy, FlushInterval: -1)
  status.go       /_core/status · /_core/api/plugins · restart endpoint
  auth.go         session token · cookie validation
  rpc.go          Register · Publish · Alert
  intents.go      Alert → every connected client
```

Roughly 600 lines. **D10 is checkable by grep:** no file in `kernel/` may contain a product noun.
A reverse proxy and a health dashboard are generic infrastructure, not product semantics.

---

## 13. Repo layout

```
proto/
  plugin/v1/plugin.proto        # Register · Publish · Alert
  client/v1/client.proto        # Plugins · Intents
  topics/v1/landmarks.proto     # LandmarkFrame  (+ future topic payloads)
backend/
  kernel/                       # §12
pluginsdk/                      # thin Go SDK over plugin/v1
plugins/
  vibecheck/  vision-macos/  todo/  activitywatch/
clients/macos-swift/            # shell: roster, webviews, native alerts
```

---

## 14. Worked example — the floor

`todo`, complete:

```go
func main() {
    h := vc.Connect()                      // reads env, Registers, reconnects on drop,
                                           // serves /health, returns handle + listener
    db := openSQLite(h.DataDir + "/todo.db")

    http.HandleFunc("/", serveUI)
    http.HandleFunc("/api/tasks", func(w http.ResponseWriter, r *http.Request) {
        switch r.Method {
        case "GET":
            json.NewEncoder(w).Encode(listTasks(db))
        case "POST":
            t := addTask(db, r)
            h.Publish("todo.created.v1", &pb.TodoCreated{Id: t.ID})
        }
    })
    http.Serve(h.Listener, nil)
}
```

No state proto, no rev counters, no Swift, no core change. Drop the directory in, restart core,
there is a tab.

---

## 15. Impact on existing code

| Existing | Fate |
|---|---|
| `proto/vibecare_plugin.proto` — `PluginService`, `RenderView`, `InvokeAction`, `ViewDescriptor`, `Node` | **Deleted.** Replaced by `proto/plugin/v1`. Core never calls the plugin (D2) and the shell renders no declarative UI (D4). |
| `proto/vibecare_plugin.proto` — `HostService` (`EmitEvent`, `Notify`, `StoreData`, `QueryData`) | **Replaced** by `PluginHost`. Storage RPCs drop entirely (D8); `Notify` becomes `Alert`. |
| `backend/pkg/pluginsdk/view.go`, `view_test.go` | **Deleted** with the view vocabulary. |
| `backend/pkg/pluginsdk/plugin.go` | **Rewritten** against the three-RPC contract. |
| `backend/internal/plugins/{registry,manifest,host_service,interceptor}.go` | **Rewritten** into `backend/kernel/`. Manifest gains `subscribes`/`publishes`/`ui`, drops `provides.actions`/`ui.entry`. |
| `backend/internal/storage/plugin_data.go` | **Deleted** (D8). |
| `backend/cmd/plugin-todos/` | **Rewritten** as `plugins/todo/` per §14 — the reference plugin. |
| `plugins/vibecheck/manifest.yaml` | **Rewritten** to the §4 schema. |
| Swift `Services/Detection/*`, `Views/VibeCheck/*`, `ViewModels/VibeCheckViewModel.swift` (~940 lines) | **Migrates out of the client.** `VisionLandmarkExtractor` + `CameraSession` → `vision-macos` plugin; `BFRBDetector` + `DetectionPolicy` + alert prefs → `vibecheck` plugin's `detect/`; `CameraPreview` + `DetectionOverlay` → HTML served by the vision plugin. `LandmarkFrame` is already the seam, so the cut is mechanical. |
| Swift client generally | Becomes a shell: roster sidebar, `WKWebView` per plugin, native alert panel. No per-plugin Swift. |

This is a large migration. §16 sequences it so the client keeps working throughout.

---

## 16. Build order

1. **Spike macOS TCC/camera attribution** (§17.1) — before anything else. It can invalidate the
   packaging of `vision-macos`.
2. **Core kernel** — supervisor, registry, health probes and state machine, bus, proxy, auth,
   three RPCs, status dashboard. Then it stops changing. The dashboard is worth building here
   rather than later: it is the debugging surface for everything that follows.
3. **`proto/client/v1` + Swift shell** — roster sidebar, one `WKWebView`, native alert panel,
   built-in dashboard tab.
4. **`todo` plugin end to end** — proves the whole loop with no camera and no migration risk.
5. **`vibecheck`** with capture compiled in behind a build tag: single binary, nothing on the bus,
   landmarks never leave the process. `LandmarkFrame` stays the internal seam. Its config UI and
   camera preview are served from its own HTTP.
6. **Extract capture → `vision-macos`** when `postures` arrives. Two camera opens means double ANE
   and double battery, so the split pays for itself only when there is a second consumer. The
   migration is mechanical because of the seam.
7. **`activitywatch` bridge** → `activity.afk.v1` → vibecheck pauses. Proves cross-plugin.
8. **`vision-linux` + conformance suite.**

Step 5 is deliberate: `vibecheck` ships as one plugin owning its own capture before the provider
split, so the client-side migration completes without waiting on the bus contract. Note that a
capture-enabled `vibecheck` is itself camera-touching and therefore inherits the §17.1 packaging
constraint — it must ship inside the app bundle. Step 6 moves that constraint to `vision-macos`
and frees `vibecheck` to become an ordinary droppable binary.

---

## 17. Risks

1. **macOS TCC / camera attribution — top risk, unchanged.** A bare binary in `plugins/` has no
   `Info.plist` and no `NSCameraUsageDescription`; the permission prompt and the Control Center
   "using camera" indicator resolve to whatever spawned it. Mitigations: ship camera-touching
   plugins **inside the app bundle** (`Contents/PlugIns/`), signed with the Team ID; run core as a
   **LaunchAgent in the GUI session**, never a system LaunchDaemon. Spike it in a day with a
   throwaway cgo binary launched exactly the way the real supervisor will launch it. **This is the
   one risk that can force a packaging change**, which is why it is step 1.
2. **cgo cost** — `vision-macos` loses pure-Go cross-compilation and needs the macOS SDK to build.
   Contained to one plugin.
3. **Landmark semantic drift** across providers — mitigated only by the §10.1 conformance suite
   and the viewer-space invariant.
4. **Reverse-proxy streaming** — MJPEG and SSE hang without `FlushInterval: -1`. Cover it with a
   test that streams through the proxy, not just a manual check.
5. **Shared web origin** (§7.5) — accepted, but plugins must not depend on `localStorage`.
6. **Webview weight** — N plugins means N `WKWebView` instances. Clients should instantiate
   lazily on first tab open and may evict background webviews.

---

## 18. Deferred on purpose

Signing and a third-party registry · sandboxing and permission enforcement · storage quotas and
core-managed backup · menubar badges and live plugin status in the shell · a TUI client (unblocked
by the `/api/*` convention, §6.2) · per-plugin origin isolation · event-log persistence and
replay · native Swift views as a per-plugin optimization.

Every item here is addable without changing the contracts in §5 and §6. Two of them — origin
isolation and enforced storage boundaries — are nonetheless expensive in implementation; see
*Revisiting decision 3* in §1 for what they cost and which v1 restraints keep them affordable.

---

## 19. Open questions

None blocking. The TCC spike (§17.1) is an unknown, not an undecided design question: it may
change how `vision-macos` is packaged and launched, but it does not change any contract in this
document.
