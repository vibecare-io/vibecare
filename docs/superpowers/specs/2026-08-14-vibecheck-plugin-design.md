# VibeCheck as a Self-Contained Swift Plugin

**Status:** design, approved for planning
**Date:** 2026-08-14
**Implements:** [plugin architecture v2](2026-08-13-plugin-architecture-v2-design.md) §16 step 5
**Supersedes for VibeCheck:** the in-client detection stack under `clients/macos-swift/VibeCare/vibecare/Services/Detection/`

---

## 1. What this builds

One plugin, `plugins/vibecheck/`, written entirely in Swift, that owns its own camera
capture. It replaces ~992 lines of detection code currently living inside the macOS
client. Landmarks never leave the process and nothing goes on the bus.

`LandmarkFrame` is preserved as an **internal seam** so that step 6 — extracting capture
into a `vision-macos` provider — is a move rather than a redesign.

This is deliberately not step 6. Two camera opens means double ANE and double battery,
so the provider split pays for itself only when a second consumer exists. Building
`vibecheck` first also completes the client-side migration without waiting on the bus
contract.

### 1.1 Why Swift rather than Go

The plugin contract is gRPC over a unix socket plus HTTP — language-agnostic by
construction. The camera and landmark code is Apple-native, and the alternative (a Go
plugin with a cgo Objective-C bridge) buys nothing here: it would still need the macOS
SDK, and it would force a rewrite of the four files that currently move untouched.

The cost is real and is accepted: **there is no Swift plugin SDK**, so this project
writes one. See §5.

---

## 2. The TCC question, settled

Spec v2 §17.1 named macOS camera attribution as the top risk and the one thing that could
force a packaging change. It was spiked on 2026-08-14 and is now closed.

**Method.** A throwaway LaunchAgent in `gui/$UID` ran a plist-less, ad-hoc, linker-signed
Go parent — an exact identity match for `bin/vibecare-server` (`Identifier=a.out`,
`Info.plist=not bound`, `TeamIdentifier=not set`) — which forked a Swift camera probe
using `supervisor.go:223-236`'s exact semantics (`exec.Command`, `Setpgid`, cwd, three env
vars). launchd as grandparent removed the terminal from the responsibility chain.

**Results.**

| Run | Probe identity | `before` | Outcome |
|---|---|---|---|
| 1 | Developer ID signed, embedded `__info_plist`, bundle id `io.vibecare.plugin.probe` | `0` notDetermined | dialog appeared; `granted=true`, camera opened |
| 2 | ad-hoc, **no** `Info.plist`, **no** bundle id, different path and filename | `3` **already authorized** | camera opened, no prompt |

System Settings → Privacy & Security → Camera showed one new entry, named **`parent`**.

**Conclusions.**

1. The TCC grant is keyed to the **responsible process — the spawner**, not the plugin.
   Run 2 proves inheritance: a binary with an entirely different identity read
   `authorized` without ever having been granted anything.
2. The permission **dialog appeared even though the parent carried no
   `NSCameraUsageDescription`**. The usage string came from the *child's* embedded
   `__info_plist`. The two roles are separate: the child supplies the prompt text, the
   parent owns the persisted grant. This refutes the "responsible process lacks the usage
   description → silent deny" reading of microsoft/vscode#307364 for this topology.
3. Therefore §17.1's mitigation — relocating camera-touching plugins into
   `Contents/PlugIns/` — is **not required**, and would not have helped: it changes the
   file's location, not the process ancestry.

**Rules this establishes:**

- **R1.** A camera-touching plugin embeds an `Info.plist` in its binary via
  `-sectcreate __TEXT __info_plist`, carrying `NSCameraUsageDescription`. This is what
  makes the prompt render.
- **R2.** A camera-touching plugin needs **no** Developer ID and **no** bundle. It stays
  an ordinary droppable binary, so `just build-plugins` keeps working for contributors
  without a signing certificate.
- **R3.** Because the grant is keyed to the spawner, it **survives plugin rebuilds**. An
  ad-hoc plugin binary gets a fresh CDHash on every build; a grant keyed to *it* would
  evaporate each time.

**Carried forward as a known UX wart, not blocking:** the Privacy → Camera row names the
server binary, not the plugin. `vibecare-server` currently signs as `a.out`. Giving it a
real identifier is worth doing and is out of scope here.

---

## 3. Architecture

```
┌──────────────────────── plugins/vibecheck/ — one Swift process ────────────────────────┐
│                                                                                         │
│  ┌───────────────────────────────── VCPluginSDK ──────────────────────────────────────┐ │
│  │  Swift port of backend/pkg/vc (§5). Reads 3 env vars, binds 127.0.0.1:0 BEFORE      │ │
│  │  Register, dials unix://, attaches x-vibecare-plugin-id to every call, runs the     │ │
│  │  Register stream and the reconnect ladder, serves GET /health.                      │ │
│  └────────────────────────────────────────────────────────────────────────────────────┘ │
│      ▲                        ▲                         ▲                    ▲          │
│  ┌───┴──────────┐   Landmark  │              ┌──────────┴───────┐   ┌────────┴────────┐ │
│  │  Capture     │   Frame     │              │    Detect        │   │      API        │ │
│  │              │ ══ SEAM ══► │              │                  │   │                 │ │
│  │ CameraSession│             │              │ BFRBDetector     │   │ GET  /          │ │
│  │  (headless)  │             │              │ DetectionPolicy  │   │ GET  /api/state │ │
│  │ VisionLmkExt │─────────────┼─────────────►│                  │   │ GET/PUT         │ │
│  │              │             │              │   BFRBEvent      │   │   /api/config   │ │
│  │ JPEG encoder │─────────────┼──────────────┼──────────────────┼──►│ GET  /api/events│ │
│  └──────────────┘             │              └────────┬─────────┘   │       (SSE)     │ │
│      ▲                        │                       │             │ GET /preview.   │ │
│  AVCaptureVideoDataOutput     │                       │             │      mjpeg      │ │
│  (front cam auto-mirrored)    │                       │             └─────────────────┘ │
│                               │                       │                      ▲          │
│  ┌────────────────────────────┴───────────────────────┴──────────────────────┴────────┐ │
│  │  Config — $VIBECARE_DATA_DIR/{config.json, alert-prefs.json, counts.json}          │ │
│  └───────────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────┬──────────────────────────┬───────────────────────────┘
                                   │ Alert()                  │ Publish()
                                   ▼                          ▼
                    core → Intents → macOS client   core bus → vibecheck.behavior_detected.v1
                    → native panel + actions (§7)   → no subscribers today (§6)
```

### 3.1 Per-frame data flow

```
AVCaptureVideoDataOutput
  │  CVPixelBuffer, 1280x720 BGRA, front camera already x-mirrored by AVFoundation
  │
  ├─► VisionLandmarkExtractor.analyze()
  │     VNDetectHumanHandPoseRequest (maximumHandCount 2)
  │     VNDetectFaceLandmarksRequest
  │     VNGeneratePersonSegmentationRequest (.fast, 64x48 mask)
  │       └─► LandmarkFrame { hands, face, hairMask, imageSize, ts, seq }
  │                │                       ── viewer space, y-down (§4) ──
  │                │
  │                ├─► BFRBDetector.detect(frame, enabled) -> DetectionResult?
  │                │     radius = 0.04 + 0.08 * clamp(sensitivity, 0, 1)
  │                │     per fingertip, first match wins: nose -> mouth -> hair
  │                │                │
  │                │                ▼
  │                │     DetectionPolicy.ingest(result, t) -> BFRBEvent?
  │                │       dwell 0.15s of CONTINUOUS presence (any gap resets all)
  │                │       exclusive across behaviors; cooldown 5s per behavior,
  │                │       checked after dwell; dwell restarts after firing
  │                │                │
  │                │                ▼
  │                │       Alert(title, body, level, actions)
  │                │       Publish("vibecheck.behavior_detected.v1")
  │                │       counts.json += 1
  │                │
  │                └─► SSE /api/events — normalized [0,1] landmarks for the overlay
  │
  └─► JPEG encode ──► /preview.mjpeg  (multipart/x-mixed-replace)
```

Analysis is throttled to 15 fps, preserved from `VibeCheckViewModel.swift:65`. Vision runs
on the capture queue; detection runs on the engine actor.

---

## 4. The coordinate decision

Vision produces normalized points with **origin bottom-left, y up**
(`Models/BFRB.swift:49-50`). Plugin architecture v2 §10.1 mandates **viewer space: origin
top-left, x right, y down**, and states that providers apply mirroring before publishing
while consumers never mirror.

**Decision: `LandmarkFrame` carries viewer space from day one.** The flip happens inside
`VisionLandmarkExtractor`, at the moment of construction — the seam never carries Vision's
convention.

The alternative — keep y-up internally and convert only at the HTML boundary — is cheaper
now and worse later: step 6 would have to change the seam's semantics at the same moment
it moves the seam across a process boundary. That is precisely the silent drift §10.1
exists to prevent.

Migrating the convention inverts five call sites, and their tests move with them:

| Site | Today (y-up) | After (y-down) |
|---|---|---|
| `BFRBDetector.isHairContact` | `p.y > face.box.maxY` | `p.y < face.box.minY` |
| `BFRBDetector.hairZone` | `y: box.maxY` | `y: box.minY - height` |
| `HairMask.isPerson` | `Int((1 - p.y) * rows)` | `Int(p.y * rows)` |
| overlay point mapping | `oy + (1 - y) * dispH` | `oy + y * dispH` |
| `drawHairMask` row test | `yUpTop = 1 - r/rows` | `r/rows` |

### 4.1 The mirroring invariant

> **AMENDED 2026-08-14, after direct measurement.** The premise below — that the front-camera
> buffer arrives already mirrored — is **false on macOS**. Measured with the session running and
> both connections active: the built-in camera reports `position = .unspecified` (not `.front`),
> `automaticallyAdjustsVideoMirroring` therefore never engages, and **neither** the data output
> **nor** the preview layer is mirrored. The client's comments asserting otherwise are wrong; no
> visible bug resulted only because its preview and its landmarks are both un-mirrored and so agree.
>
> **What the plugin does instead:** it owns both surfaces, so it applies mirroring itself —
> horizontally flipping the JPEG preview **and** the landmark x together, from one source-of-truth
> flag. Viewer space is thus genuinely the mirrored selfie §10.1 defines. This is a deliberate,
> user-visible change from the client's non-mirrored self-view.
>
> The original text is retained below because its *conclusions* about where the flip must live, and
> about reading `isVideoMirrored` per frame rather than caching it, remain correct.

Confirmed against four independent sites in the current code. The front-camera buffer is
already x-mirrored by `automaticallyAdjustsVideoMirroring`, so **x passes through
untouched and only y is flipped**. Re-mirroring x draws everything on the wrong
horizontal side.

Two corrections to the received wisdom, both load-bearing:

1. `automaticallyAdjustsVideoMirroring` is a property of `AVCaptureConnection`, **not** of
   `AVCaptureVideoPreviewLayer`. The data output's connection mirrors independently.
   Deleting `previewLayer` for headless operation therefore does *not* break mirroring —
   and because the HTML preview is encoded from the same data-output buffer the landmarks
   come from, preview and landmarks stay consistent by construction. This is safer than
   today's arrangement, where two separate paths had to agree.
2. **The invariant is device-conditional and currently unguarded.** Auto-mirroring only
   applies to front-facing devices. `AVCaptureDevice.default(for: .video)` can select an
   external USB webcam or a Continuity Camera, in which case every x is silently wrong.
   The plugin **must** read `connection.isVideoMirrored` and normalize to viewer space
   itself. This is new code with no equivalent today.

---

## 5. VCPluginSDK — the Swift port of `backend/pkg/vc`

The wire contract is fixed and frozen. What follows is the complete set of behaviors a
non-Go plugin must implement, verified against `proto/plugin/v1/plugin.proto`,
`backend/pkg/vc/vc.go`, and the kernel's own `rpc.go` / `bus.go` / `health.go` /
`supervisor.go`.

### 5.1 What already exists

- **Swift stubs are already generated**: `clients/macos-swift/VibeCare/VCStubs/plugin.pb.swift`
  and `plugin.grpc.swift`, emitted by `scripts/generate_proto.sh`. `VCKPluginHost.Client`
  is exactly the client needed.
- **UDS transport is vendored and supported**:
  `HTTP2ClientTransport.Posix(target: .unixDomainSocket(path:), transportSecurity: .plaintext)`.
  The client only ever uses `.dns(host:port:)` today, so this path is untested in-repo.
- Pin versions explicitly. Two divergent `Package.resolved` files exist in the tree and
  disagree; do not inherit from either.

### 5.2 Startup sequence — order is mandatory

1. Read `VIBECARE_SOCKET`, `VIBECARE_PLUGIN_ID`, `VIBECARE_DATA_DIR`. All three required.
2. Bind `127.0.0.1:0` and **begin accepting** — the proxy targets the port the instant
   core sets state `up`, and a bound-but-not-accepting socket produces 502s.
3. Serve `GET /health` before registering.
4. `Register(RegisterReq{id: VIBECARE_PLUGIN_ID, http_port: <actual bound port>})`.
   Core kills unregistered plugins after **10 s** (`supervisor.go:21`).
5. Handle the `CoreMsg` stream: `Ready` | `Event` | `Shutdown`.

`RegisterReq.id` **must** equal `VIBECARE_PLUGIN_ID`. Core does not cross-check it against
the call metadata (`rpc.go:63-72` reads `req.GetId()` only), so a wrong id silently
hijacks another plugin's proxy target and bus subscription.

### 5.3 Traps a naive port will hit

These are not style notes. Each one produces a broken plugin.

- **Never call `exit()` unless core asked.** `supervisor.go` charges any unrequested exit
  as a failed start; `maxFailedStarts = 5` parks the plugin in `StateFailed` until a
  manual dashboard restart. The reference Go plugin's `log.Fatalf` on ready-timeout would
  walk itself there in five attempts. A camera-permission failure, a ready-timeout, a
  `NOT_FOUND` registration — all must degrade in-process and retry.
- **A clean end of the Register stream is possible and is not an error.** When a
  non-superseded cancel closes the subscriber channel, `rpc.go:146-149` returns `nil`; in
  grpc-swift the response `AsyncSequence` simply finishes with nothing thrown. A reconnect
  loop shaped `do { for try await … } catch { retry }` falls out and never reconnects.
  Graceful completion and thrown errors must feed the same ladder.
- **Serve persistent HTTP/1.1.** The health prober uses a shared `http.Client` with
  keep-alive on and will hold an idle connection open. A listener assuming
  one-request-per-connection fails probes intermittently.
- **Attach `x-vibecare-plugin-id` to every unary call.** `callerID` returns
  `Unauthenticated` without it. `Register` does not need it but sending it is harmless.
- **Put a per-call deadline on `Publish` and `Alert`.** Neither has one in the Go SDK;
  both can block indefinitely against a wedged core.
- **SIGTERM is the only guaranteed shutdown notice.** `BroadcastShutdown` iterates live
  streams only, so a plugin mid-reconnect gets no `CoreMsg.shutdown` at all.
- **Do not put diagnostic text in `/health`'s `detail` while reporting `ok`** — core
  discards detail on any transition to `up`. Detail only ever surfaces in `degraded`.
- **Reconnect is user-visible downtime.** While the stream is down the plugin is
  `starting("reconnecting")` and `/p/vibecheck/` serves a 503 page. Prefer a tighter cap
  than the Go SDK's 30 s.

Two known Go SDK bugs must **not** be ported: the SIGTERM handler that runs the shutdown
hook without exiting, and `runShutdown`'s `sync.Once` burning if SIGTERM lands before the
hook is registered.

---

## 6. Demand refcounting does not apply to step 5

Architecture v2 §10.2 requires a provider to idle with the camera closed when nothing
subscribes. **That rule does not govern `vibecheck`, and applying it would ship a
permanently dead plugin.**

`bus.go:222` counts subscribers as plugins with an open Register stream whose *manifest*
`subscribes` list contains the topic. Today:

- the macOS client is not a bus participant — `client/v1` has only `Plugins` and `Intents`;
- no in-tree plugin declares `subscribes` at all.

So `vibecheck`, publishing `vibecheck.behavior_detected.v1`, receives
`{"subscribers": 0}` on every connect, forever. Gating the camera on that count means the
camera never opens.

Two further mechanics worth recording, since they will matter at step 6:

- A plugin with an **empty `publishes` list never receives `_core.demand.v1` at all**,
  regardless of what it subscribes to. Declaring the reserved topic in `subscribes` does
  nothing — `announceDemand` writes directly to the publisher's channel.
- Demand is authoritative **state, not a delta**. Transitions occurring while the stream
  is down are dropped, never replayed. Overwrite local state from every event received and
  expect a full burst on reconnect.

**For step 5, capture lifetime is governed by the plugin's own config** (`enabled`), and
by nothing else. The zero-demand rule attaches to `sensor.landmarks.v1` when
`vision-macos` exists.

---

## 7. Alerts

A detection today renders a `VibeNotify` modal with screen blur, a custom SVG icon,
configurable position, and a 20 s dismiss. Delivered as a plugin `Alert` it becomes an
80 px top banner, auto-dismissed after 3 s (`info`) or 8 s (`warn`), with no buttons, and
silently suppressed if the user's global notification toggle is off.

That is a real regression, and closing part of it is a **client shell change**, not a
plugin change.

**Decision: implement action-button rendering in the Swift shell as part of this work.**

The groundwork is already there and unused: `PluginAlertAction` is decoded
(`Models/PluginRoster.swift:99-118`), and `PluginRoster.url(for:path:)` exists to build an
action's target URL — nothing calls it. `PluginShellService.swift:103-119` currently logs
carried actions and drops them. Wiring `deliver()` to render them is contained, and a
button press is just an HTTP GET to `/p/vibecheck/<url>` through the existing proxy — no
new callback channel, no core change.

This restores snooze and dismiss. Explicitly **not** in scope: modal presentation, screen
blur, and custom icon rendering for plugin alerts. Those are recorded in §11.

Also noted: only `"info"` and `"warn"` exist. `"error"`, `"critical"`, and typos all
render as info.

---

## 8. Storage

`$VIBECARE_DATA_DIR` is `~/.vibecare/data/vibecheck/`, created 0700 before spawn. There
are no storage RPCs; the plugin owns everything inside it.

| File | Contents |
|---|---|
| `config.json` | `enabled`, `sensitivity` (0…1), `dwell` (new, was hardcoded 0.15), `cooldown` (1…30 s), `enabledBehaviors` |
| `alert-prefs.json` | `[String: NotificationPreferences]` keyed by behavior raw value — byte-compatible with today's `vibecheck.alert.preferences` blob |
| `counts.json` | nudge counts **keyed by date** |

Three things change versus today:

1. **`UserDefaults` is abandoned.** A bare `exec: ./vibecheck` binary has no bundle id, so
   `UserDefaults.standard` resolves to an argv0-derived domain and writes land in
   `~/Library/Preferences/`, outside the data dir. The `DetectionPreferenceStoring`
   protocol is already the seam, so this is a one-type swap.
2. **Four values that are currently RAM-only become persistent**: `sensitivity`,
   `cooldown`, `enabledBehaviors`, and `dwell`. Today every relaunch silently resets them.
3. **Nudge counts become durable and date-keyed.** Today `sessionCounts` is in-memory and
   resets on relaunch, which makes the "Nth nudge today" alert copy wrong after any
   restart.

`alert-prefs.json`'s `svgPath` values must be re-pointed. Today they embed the *client's*
`backend_url` via `NetworkConfiguration.buildIconURL`; the plugin has no such setting and
must serve its own icon assets relative to `/p/vibecheck/`.

---

## 9. HTTP surface and UI

`/api/*` is the real interface; the HTML is its first consumer. All URLs relative. No
`localStorage` — all plugins share one web origin in v1.

| Path | Serves |
|---|---|
| `GET /` | HTML UI |
| `GET /api/state` | current detection state, latest landmarks, session counts |
| `GET`/`PUT /api/config` | the `config.json` values |
| `GET`/`PUT /api/alert-prefs` | per-behavior alert preferences |
| `GET /api/events` | SSE — landmark frames and detection events |
| `GET /preview.mjpeg` | `multipart/x-mixed-replace` camera preview |
| `GET /health` | SDK default |

**`getUserMedia` is not an option.** `PluginWebView.makeNSView` builds a bare
`WKWebViewConfiguration` with no `uiDelegate`, so WebKit denies capture by default — and
even if permitted, the prompt would attribute to the client. Frames must come from the
plugin process over HTTP. This is consistent with capture being compiled in.

**Preview transport: MJPEG into an `<img>`, overlay in a separate `<canvas>`.**
`proxy.go:64-74` names the MJPEG case explicitly and `FlushInterval: -1` guarantees
per-write flush. The tradeoff is accepted: an `<img>` MJPEG stream gives JS no frame-timing
hook, so the overlay can lag or lead by a frame. Server-side compositing was rejected
because it makes the overlay non-toggleable and costs CPU per frame.

The overlay must reproduce the **aspect-fill** mapping exactly:

```
fa      = imageSize.width / imageSize.height
dispW   = viewAspect > fa ? w : h * fa
dispH   = viewAspect > fa ? w / fa : h
ox, oy  = (w - dispW) / 2, (h - dispH) / 2
point   = (ox + x * dispW, oy + y * dispH)      // y-down per §4
```

The `<img>` must therefore be `object-fit: cover`. Using `contain` drifts the overlay off
the face whenever pane aspect differs from frame aspect. The hair mask is 64x48 = 3072
cells per frame — a real `<canvas>`, never SVG rects.

---

## 10. Testing

Two tiers, mirroring how `plugins/todo/` already splits pure tests from live-kernel tests.

**Tier 1 — Swift unit tests.** `BFRBDetectorTests` (14 tests) and `DetectionPolicyTests`
(4 tests) move nearly as-is; only the module name and the coordinate convention change.
`DetectionPreferenceTests` and `DetectionAlertPreferencesStoreTests` are rewritten against
file-backed stores instead of `UserDefaults` suites. New: SDK tests for the reconnect
ladder, the clean-stream-end case, and the mirroring normalization.

**Tier 2 — one Go e2e**, `plugins/vibecheck/e2e_test.go` with its own `go.mod`, shelling
out to `swift build` where todo's shells out to `go build`. This preserves the in-process
kernel and every assertion that matters:

- on-disk state asserted **directly against the file**, not via another round trip through
  the process that wrote it;
- 401 without the session cookie;
- reachable through `/p/vibecheck/`, not merely on its own port;
- `/_core/api/plugins` reporting `state == "up"` with a non-zero pid.

Test sockets go under `os.MkdirTemp("/tmp", …)`. macOS caps `sockaddr_un.sun_path` at 104
bytes and `t.TempDir()` blows past it.

Two testing disciplines carried from the kernel build: **prove a guard can fail before
trusting it** — temporarily break the thing, watch the test go red, restore. And **an
in-memory round trip is not a persistence test**.

---

## 11. Scope boundaries

**In scope:** the plugin, the Swift SDK, the build and install recipes, alert action-button
rendering in the shell, and deletion of the client's detection stack in one final commit
once parity is reached.

**Explicitly out of scope:**

- **Porting the alert customization editor.** `VibeCheckAlertSettingsView.swift` is 45
  lines that reuse the client's entire `NotificationCustomizationView` — icon picker,
  position, blur, geometry, presets, live preview. Reimplementing that as plugin HTML is
  the single largest item in this migration and is deferred. v1 ships the stored
  preferences with a minimal editor.
- Modal/blurred alert presentation for plugin alerts.
- `proto/topics/v1/landmarks.proto`. The seam stays an internal Swift type; the proto
  arrives with step 6.
- Two-handed detection. `extractHand` reads `results?.first` only, despite
  `maximumHandCount = 2`. Recorded as an existing limitation, not fixed here.
- The 21-joint MediaPipe topology. Today only 5 fingertips are extracted, filtered at
  confidence 0.3, giving a variable-length 1…5 array. §10.1's wire contract wants 21
  positionally-indexed joints; that conversion belongs to step 6.

### 11.1 The unresolved contract conflict

§10.1 specifies `Face.scalp_line` as a repeated `Point` polyline. The working
implementation uses `HairMask`: a 64x48 boolean grid from
`VNGeneratePersonSegmentationRequest`. **These are not interconvertible**, and 3072 bools
per frame has no natural proto encoding.

This is the one place where the spec's proto and the shipping code genuinely disagree. It
does not block step 5 — the seam is internal, so `HairMask` simply stays on it. It **must**
be resolved before step 6 publishes `sensor.landmarks.v1`. Recorded here so it is not
discovered late.

---

## 12. Build and install

```
plugins/vibecheck/
  Package.swift            swift-tools-version 6.0, platforms [.macOS(.v15)]
  Info.plist               CFBundleIdentifier io.vibecare.plugin.vibecheck
                           NSCameraUsageDescription (text from pbxproj:493)
  manifest.yaml            id: vibecheck / exec: ./vibecheck / ui: webview
  Sources/
    VCKStubs/              plugin.{pb,grpc}.swift only
    VCPluginSDK/           §5
    vibecheck/             main.swift, Capture/, Detect/, API/, Config/
  Tests/
  ui/                      HTML/CSS/JS
  e2e_test.go, go.mod      §10 tier 2
```

```bash
cd plugins/vibecheck
swift build -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
cp .build/release/vibecheck ./vibecheck      # next to manifest.yaml
```

Per **R2**, no `codesign` step. The `-sectcreate` flags go on the command line, not in
`linkerSettings.unsafeFlags` — a package using `unsafeFlags` cannot be consumed as a
versioned dependency.

`just build-plugins` gains `build-vibecheck-plugin`. Landing the artifact at
`plugins/vibecheck/vibecheck` means the existing `install-plugins` loop finds it by its
existing `[ -x "$dir/$id" ]` convention — **`install-plugins` needs no change**, which is
worth preserving. `proto-gen` gains a step emitting plugin stubs into
`plugins/vibecheck/Sources/VCKStubs`; path-depending on the client's `VCStubs` product
would drag in ~700 KB of unrelated stubs.

Live reload (`build-plugins-dev`, Go's `-tags dev`) has no Swift equivalent in v1 and is
skipped.

### 12.1 Manifest

```yaml
id: vibecheck
name: VibeCheck
icon: eye.trianglebadge.exclamationmark
exec: ./vibecheck
publishes: [vibecheck.behavior_detected.v1]
ui: webview
```

Only `id` and `exec` are required. `exec` resolves against the manifest's own directory.
Discovery runs **once**, in `Kernel.Start` — there is no hot-add and no manifest reload, so
any manifest change requires a core restart.

---

## 13. Migration and deletion

The client keeps working throughout. Deletion happens in **one commit at the end**, once
the plugin reaches parity — the same way v1 was removed.

Moves untouched (modulo §4's coordinate flip): `BFRBDetector`, `DetectionPolicy`,
`VisionLandmarkExtractor`, `BFRB.swift`, and their 18 tests.

Rewritten: `VibeCheckViewModel` (the `@MainActor`/`ObservableObject`/singleton shape
becomes one engine actor; its three `nonisolated(unsafe)` escape hatches vanish because the
main-actor boundary they cross ceases to exist), `DetectionPreference`,
`DetectionAlertPreferencesStore`, `InterruptPlayer` (`NSSound` → AudioToolbox or delegate
to the alert).

Rewritten as HTML: `CameraPreview`, `DetectionOverlay`, `VibeCheckControlsPanel`,
`VibeCheckAlertSettingsView`.

Deleted: `VibeCheckScreen` — the roster provides the tab.

Wiring to remove, beyond what the handoff listed: `Dashboard.swift` (5 sites),
`Sidebar.swift` (4 sites), `DashboardState.swift:9` and `:29-30`, `App.swift:38-39`,
`PlaceholderViews.swift:178` and `:244-246`, and
`VibeNotifyConfiguration.swift:253-311`. Deleting the `SidebarItem` enum case makes the
compiler find the exhaustive-switch sites.

One deep link must not be lost: `VibeCheckScreen.swift:63` opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_Camera` when permission is
denied. A web UI cannot open that URL; it becomes an alert action or a small plugin
endpoint that shells out to `open`.

**Not deleted:** `Models/NotificationPreferences.swift` and
`Views/Schedules/NotificationCustomizationView.swift` — both are shared with the schedule
notification feature, which stays in the client. The plugin needs its own copy of the
`NotificationPreferences` Codable shape to read the migrated JSON. That duplication is
unavoidable.

---

## 14. Kernel discipline

**D10 still binds.** No product noun — `vibecheck`, `detection`, `behavior`, `camera`,
`posture`, `todo` — may appear in any `backend/kernel/*.go` file, comments and test
fixtures included. `TestKernelContainsNoProductNouns` fails the build. Nothing in this
design requires a core change, so D10 should never come under pressure; if it does, that
is a signal the design has drifted.
