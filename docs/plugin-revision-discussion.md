# vibecare — Plugin Architecture Research

**Status:** design settled, nothing built yet. Handoff doc for a Claude Code implementation session.
**Date:** 2026-08-13
**Stack:** Go core daemon · protobuf/gRPC over unix socket · Swift macOS client · (later) Linux TUI

---

## 0. The product

Desktop app for posture, habits, schedules. Native UX, explicitly not Electron.
Plugins in scope:

| Plugin | Does |
|---|---|
| `vision` | camera → hand/face landmarks (provider) |
| `vibecheck` | detects repetitive body-focused behaviors (nail-biting, nose-picking, hair-pulling), alerts |
| `postures` | posture scoring from the same landmarks |
| `todo` | task management |
| `activitywatch` | bridge to the external ActivityWatch program (app/browser/editor usage) |

---

## 1. Decisions (settled)

1. **Microkernel + event bus.** Core = bus, state store, router, supervisor, KV host, scheduler. Core contains **zero** product semantics — never the words "posture", "nailbiting", "todo".
2. **Clients render only.** No camera, no logic, no plugin knowledge. Client contract is 3 rpcs, forever.
3. **Plugins own everything else** — their logic, their data, their UI state.
4. **Unidirectional loop:** Actions flow up (client → core → owning plugin). State flows down (plugin → core → all clients) as **full snapshots**, never patches.
5. **Sensor providers are plugins, not clients.** `vision-macos` (Swift, in app bundle) and later `vision-linux` publish the same `sensor.landmarks.v1` topic.
6. **geometry = platform · meaning = plugin.** Pixels→landmarks is platform work; landmarks→meaning exists exactly once.
7. **v1 packaging: plugins compiled into the core binary as Go packages.** Everything crossing the boundary is already a proto message, so extracting to subprocesses later is mechanical. Exception: `vision-macos` may need to be a separate bundled binary from day one (see §8 TCC spike).

### Three channels — keep them distinct in code and in protos

| Channel | Shape | Recipients | Durability | Fails? |
|---|---|---|---|---|
| **Action** (client → core → one plugin) | command | exactly one | n/a | yes → `Unavailable` |
| **Event** (plugin → bus → subscribers) | fact, past tense | 0..n | ephemeral by default | no — fire & forget |
| **State** (plugin → core → all clients) | snapshot | every client | retained, latest-wins | no |

Never tunnel request/response through pub/sub. Never let clients call plugins directly.

---

## 2. Data model — four stores, don't mix them

| Kind | Owner | Storage | Read by |
|---|---|---|---|
| Domain state (tasks, episodes, streaks) | plugin | `~/.vibecare/data/plugins/<id>.db`, namespaced, **core-hosted** | that plugin only |
| Bus events | nobody | none (ephemeral) | live subscribers |
| Event log | core | opt-in **per topic** with TTL in topic registry | history queries |
| Retained state | core | `core.db`: `(plugin_id, rev, blob)` — latest only | all clients |

Rules:
- `plugin_id` comes from the handshake and **is** the KV namespace — a plugin cannot express "read another plugin's data".
- One sqlite file per plugin: uninstall = delete one file; corruption contained; one writer per namespace so concurrency is trivial.
- Values are protobuf blobs whose schemas the plugin owns. Core stores bytes. Migrations are the plugin's job.
- **The DB is never how plugins share data.** Cross-plugin = bus topics or service calls.
- Escape hatch (rare): `storage:file` permission in manifest → private data dir, plugin runs its own db, forfeits core-managed backup/quota.

### PUSH vs PULL — the sizing rule

> **PUSH = state the user sees. PULL = questions the user asks.**

State proto test: *"is every field visible on screen when the app is idle?"* If no, it belongs in KV (pull on navigation) or on the bus (ephemeral).

Worked example — vibecheck is a funnel:

```
10/sec   sensor.landmarks.v1     → ephemeral bus, never stored, never pushed
~50/day  detection episodes      → plugin's own sqlite (private, forever)
~50/day  VibecheckState (~300B)  → retained, rev++, fanned to clients
~1/day   "last 30 days" screen   → PULL: Act{query_history} → aggregates
```

There is **no `ListTodos`**. "List all todos" = replay of the retained `TodoState` at connect. A plugin must `PushState` unconditionally in `Start()` — including the empty state — so the retained table is never missing an enabled plugin.

---

## 3. Contracts

### 3.1 Client ↔ core (`proto/client/v1/`) — three rpcs, frozen

```proto
service Vibecare {
  rpc Updates(Empty) returns (stream StateUpdate);  // all plugin UI state, down
  rpc Act(Action) returns (Ack);                    // all user input, up
  rpc Intents(Empty) returns (stream UIIntent);     // transient alerts, down
}
message StateUpdate { string plugin = 1; uint64 rev = 2; google.protobuf.Any state = 3; }
message Action      { string plugin = 1; string name = 2; google.protobuf.Struct args = 3; }
message UIIntent    { oneof k { Alert alert = 1; } }   // never retained
```

Surface lifecycle in core:
1. plugin pushes full snapshot
2. core hashes it; identical → drop silently (plugins may re-push defensively for free)
3. changed → `rev++` (core owns the counter), overwrite retained row, fan out to all clients
4. client: `if update.rev <= current { discard }` — one integer compare is the entire consistency protocol
5. on connect: core replays every retained row. Zero plugin round-trips.

Free properties: instant render on relaunch; a crashed plugin's panel still displays (only *interacting* fails, with `Unavailable` + offline badge); a second client/TUI costs nothing; core may coalesce (max 1 fan-out/plugin/sec, keep newest) with zero risk because latest-wins.

**Rendering:** each plugin defines its own state proto (`TodoState`, `VibecheckState`) and Swift has a bespoke native view per type — no universal UI language to design. Generic primitives (`Card`, `ListPanel`, `SettingsForm`) exist as the floor for plugins with no bespoke view. Start with those three only; grow the vocabulary only when a real plugin hits the ceiling.

### 3.2 Plugin ↔ core (`proto/plugin/v1/`)

v1 as a Go interface (same shape as the eventual gRPC service):

```go
type Plugin interface {
    ID() string
    Start(h Host) error
    Stop() error
}

type Host interface {
    Publish(topic string, msg proto.Message)      // topic inferred from type via codegen
    Subscribe(topic string, fn func(*pb.Event))
    KV() KV                                       // namespaced to plugin id
    PushState(msg proto.Message)                  // full snapshot → clients
    EmitIntent(*pb.UIIntent)                      // transient alert
    OnAction(fn func(*pb.Action))
    Call(service string, req proto.Message) (proto.Message, error)  // sync, mediated
    Every(d time.Duration, fn func())
}
```

Manifest (JSON in v1, proto later):

```json
{
  "id": "vibecheck", "version": "0.1.0", "host_api": 1,
  "subscribes": ["sensor.landmarks.v1", "activity.afk.v1"],
  "publishes":  ["vibecheck.behavior_detected.v1"],
  "services":   [],
  "permissions": [],
  "config_schema": { }
}
```

- `host_api` = one integer, bumped only when `plugin.proto` itself changes. Topic payloads evolve independently via versioned topic names.
- `requires` is for **platform capabilities**; other plugins belong in `optional`. **Every plugin must work correctly with all others disabled.** Cross-plugin behavior is always an enhancement gated on presence.
- Codegen a compile-time topic↔payload-type mapping from `proto/topics/` so publishing the wrong shape doesn't compile.

### 3.3 Sensor contract (`proto/topics/v1/landmarks.proto`) — load-bearing

```proto
message LandmarkFrame {
  google.protobuf.Timestamp ts = 1;
  repeated Hand hands = 2;      // 0..2
  Face face = 3;                // optional
  float fps_hint = 4;
}
message Hand { repeated Point joints = 1;  // 21, MediaPipe topology order
               Handedness handedness = 2; float confidence = 3; }
message Face { Rect bounds = 1; Point nose_tip = 2; Point mouth_center = 3;
               Point chin = 4; repeated Point scalp_line = 5; float confidence = 6; }
// all coords normalized 0..1 in frame space. NO pixels in this file, ever.
```

Must be nailed down and tested, because two independent implementations feed this topic and silent drift = "vibecheck fires constantly on Linux":
coordinate origin · joint ordering · **mirroring convention (front-camera flip)** · confidence scale · empty-frame vs no-message semantics.
**Conformance suite: one recorded video → both providers → assert landmark agreement within tolerance.**

---

## 4. Where code lives

| Work | Home | Why |
|---|---|---|
| Camera capture, permission prompt | `vision-<os>` plugin | platform-specific by nature |
| Landmark inference (Vision/ANE, MediaPipe) | `vision-<os>` plugin | platform-optimal; pixels never cross a process boundary |
| Zone geometry, dwell timing | `vibecheck` | identical math everywhere |
| Behavior state machine (debounce, hysteresis, episodes) | `vibecheck` | the product; tuned weekly |
| Policy (sensitivity, cooldown, quiet hours, afk pause) | `vibecheck` | config-driven |
| Episode log, stats, streaks | `vibecheck` KV | outlives any client |
| Alert popup rendering | client | NSPanel vs notify-send |
| Live camera preview (calibration) | client-local, bypasses the pipeline entirely | 30fps video is not plugin UI state |

**Refuse:** any classification logic in Swift. Landmarks are the highest-level thing a provider may compute.

Provider plugins are written natively per platform **because their entire content is platform-specific** — capture glue + one inference call + publish, no shared logic to keep in sync. A provider only needs handshake + publish-one-topic (~50 lines of gRPC); no full SDK per language.

### vibecheck layout

```
plugins/vibecheck/
  main.go                 # sdk.Run — handshake, bus, KV, state pushes
  detect/                 # pure Go, platform-free, unit-testable from fixtures
    zones.go  statemachine.go  policy.go  episodes.go
  capture/                # V1 SHORTCUT ONLY — see §7
    capture.go            # type Provider interface { Frames(ctx) <-chan LandmarkFrame }
    vision_darwin.go/.m   # cgo → AVFoundation + VNDetectHumanHandPoseRequest
    mediapipe_linux.go
```

### Repo

```
proto/
  client/v1/     plugin/v1/     topics/v1/     <plugin>/v1/
backend/
  kernel/        # bus, retained store, router, supervisor, KV host, scheduler
  plugins/       # vibecheck/ todo/ activitywatch/ postures/
pluginsdk/       # thin Go SDK over plugin/v1
clients/macos/
  Plugins/<X>View.swift
```

---

## 5. Adding a new plugin — the whole cost

1. `proto/<plugin>/v1/` — state message + action names + event payloads
2. `plugins/<plugin>/` — Subscribe · KV · Publish · PushState · OnAction
3. `clients/macos/Plugins/<X>View.swift` — render state proto, send Actions *(skip if a generic SettingsForm/Card suffices)*

**Core: 0 changes. Transport: 0 changes.**

Plugin skeleton:

```go
func main() {
    sdk.Run(sdk.Plugin{
        Manifest: manifest,
        OnStart:  render,                          // MUST push state unconditionally
        Actions:  sdk.Actions{"add": add, "toggle": toggle},
        Events:   sdk.Events{"vibecheck.behavior_detected.v1": onBehavior},
    })
}
func add(ctx sdk.Ctx, a sdk.Action) error {
    t := Task{ID: sdk.NewID(), Title: a.Str("title")}
    ctx.KV().Put("task/"+t.ID, &t)
    ctx.Publish(&pb.TodoCreated{Id: t.ID})   // for OTHER PLUGINS
    return render(ctx)                        // for CLIENTS
}
func render(ctx sdk.Ctx) error {              // state → FULL snapshot
    return ctx.PushState(&pb.TodoState{Tasks: allTasks(ctx.KV())})
}
```

Handler shape is always: **handle input → mutate KV → publish fact → push full snapshot.** Idempotent by construction.

### Tooling (build early — decides whether plugins are actually pleasant)

- `vibecare plugin init <name>` — scaffold manifest, main.go, proto stubs
- `vibecare dev run ./<plugin>` — spawn against live core, skip verification, restart on rebuild
- `vibecare bus tail` / `vibecare bus emit <topic> '<json>'` — watch traffic, inject fake events (develop todo's coach feature with no camera, no vibecheck)
- `sdktest.NewHost()` — in-memory fake host; call handler, assert published events + pushed state, no processes

---

## 6. Config UI

| Config type | Mechanism |
|---|---|
| Toggles, sliders, selects, thresholds, quiet hours (~95%) | JSON-schema in manifest → core → **native `SettingsForm`** on every client, incl. TUI |
| Genuinely visual (camera preview, drawing detection zones) | `ui:webview` **declared capability**; plugin serves localhost HTTP; client embeds WKWebView; MJPEG the preview |

Webview is an escape hatch, not the default. A plugin whose only config path is HTML is unusable from a TUI. Clients that can't render it degrade to "open in browser".

---

## 7. Build order

1. **Spike TCC/camera** (§8) — do this before writing anything else.
2. Core kernel: bus (Go channels), retained state store + rev/hash, action router, KV host. ~500 lines, then never changes.
3. `client/v1` protos + Swift shell that renders a hardcoded state proto.
4. `todo` plugin end-to-end — proves the whole loop with no camera.
5. `vibecheck` with `capture/` compiled in behind a build tag (single binary, nothing on the bus). Landmarks never leave the process; `LandmarkFrame` is still the internal seam.
6. Extract `capture/` → `vision` plugin **when `postures` arrives** (two camera opens = double ANE + battery). Migration is mechanical because of the seam.
7. `activitywatch` bridge → `activity.afk.v1` → vibecheck pauses. Proves cross-plugin.
8. Linux TUI / `vision-linux` + conformance suite.

Deferred on purpose: subprocess plugin host, signing, WASM, generic primitive expansion, event-log replay.

---

## 8. Open risks

1. **macOS TCC / camera attribution — the top risk.** A bare binary in `~/.vibecare/plugins/` has no Info.plist / `NSCameraUsageDescription`; the prompt and the Control Center "using camera" entry resolve to whatever spawned it. Mitigations: ship sensor plugins **inside the app bundle** (`Contents/PlugIns/`), signed with your Team ID; run the host as a **LaunchAgent in the GUI session**, not a system LaunchDaemon; grant the `camera` capability only to bundle-resident plugins (third parties get landmarks off the bus, never raw camera). **Spike it in a day** with a throwaway cgo binary launched the way the real host will launch it.
2. **cgo cost** — loses pure-Go cross-compile; needs macOS SDK to build.
3. **Landmark semantic drift** across providers — mitigated only by the conformance suite.
4. **Demand-driven capture** — provider must idle (camera closed, LED off) at 0 subscribers; core refcounts subscriptions and signals the provider.
5. **State bloat** — enforce the "visible on screen when idle" test in review; coalescing in core as backstop.

---

## 9. Discipline (the things that are expensive to retrofit)

- Plugins never import each other and never read each other's KV. Bus topics or mediated service calls only.
- No raw SQL over the plugin RPC. Grow the host API by intent (`Scan(prefix, range)`, timeseries service) instead.
- Recovery = **pull current state** from the owner's service. Never synthesize compensating events; fabricated history is indistinguishable from real history. Treat every subscription as best-effort.
- No plugin-specific endpoint exposed directly to clients "just this once" — that re-couples every client to every plugin and kills the retained-store guarantees. If a primitive is missing, add a primitive.
- `RBFB` / `postures` detectors inside vibecheck are **files implementing a `Detector` interface**, not separate plugins. Promote only if one needs its own lifecycle/config/UI.

---

## 10. Prior art (each piece is shipped somewhere)

| Concept | Reference implementation |
|---|---|
| Core daemon + thin native clients | Neovim, Docker, Tailscale |
| Subprocess plugins over gRPC | Terraform / Vault (`hashicorp/go-plugin`) |
| Event bus + entities + swappable integrations | **Home Assistant** (closest full analog) |
| Publish full UI snapshot → native render → action callback | **Slack App Home** (`views.publish` + Block Kit) |
| Typed semantic data, each client renders natively + capability negotiation | **LSP** |
| Retained state rendering while producer is asleep | iOS WidgetKit, MQTT retained messages |
| Namespaced plugin storage, manifest ergonomics | VS Code extensions (Memento) |
