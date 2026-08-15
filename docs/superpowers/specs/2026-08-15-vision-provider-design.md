# Vision as the Foundational Provider Plugin

**Status:** design, approved for planning
**Date:** 2026-08-15
**Implements:** [plugin architecture v2](2026-08-13-plugin-architecture-v2-design.md) §16 step 6
**Amends:** v2 §10.1 (topic names, sensor contract), v2 §10.2 (demand)
**Supersedes for capture:** [vibecheck plugin design](2026-08-14-vibecheck-plugin-design.md) §1, §6, §11.1

---

## 1. What this builds

`plugins/vision/` — one Swift plugin that owns the camera and publishes what it sees as a
tiered set of bus topics. Every camera-derived feature becomes a small consumer of those
topics instead of a second camera opener:

| Plugin | Consumes | Produces |
|---|---|---|
| `vision` | `vision.request.v1` | the five `vision.*` topics below |
| `vibecheck` | `vision.{face,hands,segmentation}.v1` | BFRB alerts |
| `postures` | `vision.{body_pose,signals}.v1` | posture nudges |
| `blink-jump` | `vision.signals.v1` | a game |

This is v2's step 6, deferred at the time because "two camera opens means double ANE and
double battery, so the provider split pays for itself only when a second consumer exists"
([vibecheck design](2026-08-14-vibecheck-plugin-design.md) §1). Two more consumers now
exist, so it pays.

**Sequencing:** vision first, vibecheck cut over to it, then postures and blink-jump
written against the proven contract. The riskiest step — parity on shipped behaviour —
goes first, and there is never a moment with two camera opens.

---

## 2. The rule that keeps vision generic

> Vision may publish anything that is a **measurable property of the body**.
> It may never publish a **judgement about behaviour**.

| Vision publishes (geometry) | A plugin decides (meaning) |
|---|---|
| `ear_l = 0.11` | "blinked" → jump |
| `yaw = -18°` | "looking away from the screen" |
| `shoulder_angle = 12°` | "slouching for four minutes" → nudge |
| `fingertip_to_nose = 0.03` | "nose-picking, 6th today" → alert |

This is v2 §1.6's "geometry = platform · meaning = plugin", read at the right thickness.
Landmarks-only reads it too thinly: blink-jump, vibecheck and postures would each
re-derive eye and head geometry from raw points, and each would drift.

A derived signal ships only if it passes all three tests:

1. it is a **measurable property of the body**, not a judgement about behaviour;
2. it is derivable from landmarks vision **already computed** for some other consumer;
3. it has a **right answer on a recorded clip**, so a test can fail.

`is_blinking`, `is_slouching` and `nail_biting` each fail (1) and (3). That triple is what
keeps the signals tier from rotting into a junk drawer, and it is the only thing that does.

---

## 3. Naming

Two kinds of topic, distinguished by whether more than one implementation could ever
satisfy them:

> **Interface topics** name a capability → **domain** prefix. Consumers bind to the
> capability, not to the producer.
> **Product topics** carry facts only one plugin can produce, in its own vocabulary →
> **plugin-id** prefix.

`vibecheck.behavior_detected.v1` is a product topic: nothing else can produce
"nose-picking detected". Face landmarks are a capability, so they take the `vision.`
domain prefix.

**The plugin id is `vision`, not `vision-macos`.** v2 §16 step 6 called it `vision-macos`
in anticipation of a Linux sibling that does not exist. YAGNI: the shorter id is what
everyone types today. `bus.go:229` already supports two plugins publishing one topic, so a
future `vision-linux` publishing `vision.face.v1` works — it merely reads slightly odd,
which is a cosmetic cost paid later instead of a suffix paid now.

`sensor.*` from v2 §10.1 is retired: `sensor` is too broad to be a domain, since
`sensor.face.v1` and a hypothetical `sensor.keyboard_idle.v1` share nothing.
`vision.*`, `audio.*` and `activity.*` are peer domains that each mean something.

Renaming is free **today** — `sensor.landmarks.v1` exists only in prose; nothing in the
tree publishes or subscribes to it. It would cost a migration the day after something ships.

---

## 4. Topic contracts — `proto/topics/v1/vision.proto`

One topic per **Vision request**, because ANE cost is per-request, not per-landmark.
`VNDetectFaceLandmarks` returns all 76 points in one shot, so splitting "eyes" and "nose"
into separate topics would save a few bytes and exactly zero compute. Matching topics to
requests is what makes the demand refcount a truthful cost model.

Every payload opens with the same header so tiers can be joined:

```proto
message Header {
  google.protobuf.Timestamp ts = 1;
  uint64 seq       = 2;   // monotonic per provider; SHARED by every topic
                          // derived from one frame. Gaps mean dropped frames.
  string device_id = 3;   // which camera, when several exist
  Size   frame     = 4;   // source pixel dimensions
}
message Point { float x = 1; float y = 2; }   // normalized 0..1, viewer space
message Rect  { float x = 1; float y = 2; float w = 3; float h = 4; }
message Size  { uint32 w = 1; uint32 h = 2; }
```

| Topic | Payload | Cost |
|---|---|---|
| `vision.face.v1` | `Header`, `Rect bounds`, 76 `Point`, `float confidence` | `VNDetectFaceLandmarksRequest` |
| `vision.hands.v1` | `Header`, 0–2 × `Hand{21 Point, Handedness, confidence}` | `VNDetectHumanHandPoseRequest` |
| `vision.body_pose.v1` | `Header`, 19 × `Joint{Point, confidence}` | `VNDetectHumanBodyPoseRequest` |
| `vision.segmentation.v1` | `Header`, `uint32 w`, `uint32 h`, `bytes mask` | `VNGeneratePersonSegmentationRequest` |
| `vision.signals.v1` | `Header`, every field `optional` (§4.2) | free — pure math |
| `vision.request.v1` | §5 — published by consumers, subscribed by vision | — |

An empty frame (no face, no hands) is a **valid published message** meaning "nothing
detected". *No message* means the model is not running. Consumers must treat these
differently.

### 4.1 Segmentation, and the death of `scalp_line`

v2 §10.1 specified `Face.scalp_line` as a repeated `Point` polyline. The shipping
implementation uses a 64×48 boolean grid from `VNGeneratePersonSegmentationRequest`.
[vibecheck design §11.1](2026-08-14-vibecheck-plugin-design.md) recorded these as
non-interconvertible and flagged it as the one thing that must be resolved before any
landmark topic is published.

**Resolved: `scalp_line` is deleted. The mask gets its own topic**, carrying
`w`, `h` and a row-major **packed bitmask** — 64×48 → 384 bytes, which is a perfectly
natural proto payload. The conflict existed only because a 3072-cell grid was being forced
into the face message. Splitting by Vision request dissolves it as a side effect.

### 4.2 The signals tier

```proto
message Signals {
  Header header = 1;
  optional float ear_l = 2;              // eye aspect ratio, per eye
  optional float ear_r = 3;
  optional float yaw = 4;                // head pose, degrees
  optional float pitch = 5;
  optional float roll = 6;
  optional float shoulder_angle = 7;     // degrees off horizontal
  optional float neck_forward = 8;       // normalized forward-head distance
  optional float fingertip_to_nose = 9;  // min over fingertips, normalized
  optional float fingertip_to_mouth = 10;
}
```

**Every field is `optional`, and absent is not zero.** A field is absent when the model
that feeds it is not running — `ear_l` is missing whenever nobody has asked for faces.
A consumer reading absent as `0.0` sees a permanently closed eye.

Signals are computed by `VCGeometry`, an internal Swift target of the vision plugin. It is
deliberately **not** shipped as a package for consumers to link: same benefit (the math is
written and tested once), none of the cost (no language lock-in, no cross-process
distribution problem, no per-consumer CPU). If a Swift consumer later wants to link it,
that is a decision made then, not a contract owed now.

### 4.3 Coordinate convention

> All coordinates are **viewer space**: the frame as the user sees themselves in a mirrored
> selfie preview. Origin top-left, `x` right, `y` down, normalized `0..1`. Vision applies
> mirroring **before** publishing. Consumers never mirror.

Unchanged from v2 §10.1 except that v2's justification was wrong and was already corrected
in the vibecheck design's 2026-08-14 amendment: the built-in Mac camera reports
`position = .unspecified`, so `automaticallyAdjustsVideoMirroring` never engages and
**nothing arrives pre-mirrored**. Vision reads `connection.isVideoMirrored` per frame —
never cached, never inferred — and flips the JPEG preview and the landmark `x` together
from one source-of-truth flag.

### 4.4 The override ladder

Publishing both tiers is what makes vision flexible without making it configurable:

| Need | Rung | Cost |
|---|---|---|
| "the blink threshold feels wrong" | own logic on `ear_l`/`ear_r` | tier 1 |
| "I want a 6-point EAR, not 3-point" | subscribe `vision.face.v1`, derive it | tier 0 |
| "Apple's model is wrong for me" | ship a second provider on the same topics | provider |

Day one, blink-jump is ~50 lines against `vision.signals.v1`. The day it outgrows that it
drops to `vision.face.v1` **with no change to vision at all** — the points were already
computed for someone else, so keeping the lower rung available costs nothing.

---

## 5. Control plane — two mechanisms, no kernel change

Vision must be light *based on usage*: a user tracking only their head should pay for one
Vision request, not four. Two independent mechanisms cooperate, each doing the job it is
actually good at.

```
  ┌── kernel demand refcount ──────────────┐   ┌── vision.request.v1 ─────────┐
  │ truthful about LIVENESS                │   │ truthful about INTENT        │
  │ 0 subscribers → camera CLOSED, always  │   │ {requester, topics[], fps,   │
  │ already built, product-free            │   │  ttl_s}, latest-wins per     │
  │ the privacy FLOOR                      │   │  requester, TTL 30s          │
  └────────────────────────────────────────┘   └──────────────────────────────┘
                          └───── vision runs the union ─────┘
```

### 5.1 Why the kernel does not learn about this

The obvious design is a new `SetSubscriptions` RPC letting a plugin change its subscription
at runtime. It was rejected. `Bus.Declare` (`bus.go:82`) reads subscriptions from the
manifest by design — *"core knows what to deliver before the plugin ever connects"* — and a
runtime override means a fourth RPC, a change to both SDKs, and re-assertion logic on every
reconnect. Adding `fps` on top means the kernel knows what a frame is, which is product
semantics one field away from D10.

The request topic gets the same result with **zero kernel change**, because it is an
ordinary declared topic on both sides and the manifests stay honest.

### 5.2 What each mechanism knows

`announceDemand` (`bus.go:229`) already delivers `DemandPayload{Topic, Subscribers}` — **per
topic** — to every plugin declaring that topic in `publishes`. So `vision.body_pose.v1` at
zero subscribers means `VNDetectHumanBodyPoseRequest` is never constructed. That is free
today.

What demand **cannot** know: subscriber count is manifest-declared subscription plus an open
Register stream. It measures *process liveness*, not *user intent*. There is no
enable/disable concept anywhere in `backend/kernel/` — a discovered plugin runs until core
exits. So a user who switches vibecheck off in its own UI leaves the process up and
subscribed, demand stays at 1, and the camera stays open with the LED on. That is precisely
the case v2 §10.2's privacy claim needs to cover and currently cannot.

`vision.request.v1` covers it. The behaviours that fall out:

- user disables vibecheck → it publishes `{topics: []}` → hands and segmentation requests
  are destroyed, though its process stays up and subscribed
- every consumer disabled → union empty → **capture session stopped, LED off**
- postures installed later → `{topics: [body_pose]}` → the body model is constructed,
  **vision unchanged, no release**
- a consumer wedges → its request expires by TTL
- a consumer dies → the demand floor closes the camera regardless of stale requests

### 5.3 Request payload and its one wart

```proto
message Request {
  string requester = 1;          // self-asserted; see below
  repeated string topics = 2;    // desired vision.* topics; [] means "nothing"
  uint32 fps = 3;                // desired rate; vision runs max() across requesters
  uint32 ttl_s = 4;              // default 30
}
```

Desired-state, latest-wins per `requester`, re-asserted on every reconnect and on a
heartbeat well inside the TTL (10 s against a 30 s TTL). An `fps` of 0 or absent means the
default, 15.

**Subscribing without requesting yields nothing, and that must be loud.** Demand governs
whether vision *may* run a model; the request union governs whether it *does*. A consumer
that declares `subscribes: [vision.face.v1]` but never publishes a request will sit there
receiving no events at all, which is indistinguishable from a broken bus. Vision therefore
logs `subscriber with no request topic=<t> subscribers=<n>` whenever demand for a topic is
non-zero while no live request names it, and surfaces the same line in its `/api/state`
readout. This is the single most likely way to wire a new consumer up wrong.

**`BusEvent` carries `{Topic, Payload, TS}` and not the publisher id**, and `Event` in
`proto/plugin/v1/plugin.proto` has no source field either. So a request self-identifies via
`requester` and is **not authenticated**. This is acceptable because the channel cannot
grant capability — it can only ask for work that the demand floor still gates — but it is a
real limitation and is recorded here rather than discovered later. Adding
`source_plugin_id` to `Event` is a small, product-free kernel change available if it ever
matters.

### 5.4 The pub/sub exception, taken explicitly

[plugin-revision-discussion.md](../../plugin-revision-discussion.md) §1 says *"never tunnel
request/response through pub/sub"*. This design does not violate it: nothing here expects a
reply, and if vision is down, consumers publish into the void and nothing breaks. It is a
consumer broadcasting its own desired state, which is exactly what an event is. Recorded as
a deliberate reading of the rule rather than an oversight of it.

### 5.5 Manifests

The manifest is the **permitted** set; the request topic picks the active subset at runtime.
Discovery runs once in `Kernel.Start` — there is no hot-add, so any manifest change needs a
core restart.

```yaml
# plugins/vision/manifest.yaml
id: vision
name: Vision
icon: eye
exec: ./dist/vision
subscribes: [vision.request.v1]
publishes:  [vision.face.v1, vision.hands.v1, vision.body_pose.v1,
             vision.segmentation.v1, vision.signals.v1]
ui: webview
build: just build-vision-plugin     # -sectcreate Info.plist + ad-hoc codesign (§8.1)
```

```yaml
# plugins/vibecheck/manifest.yaml — after the cutover
subscribes: [vision.face.v1, vision.hands.v1, vision.segmentation.v1]
publishes:  [vision.request.v1, vibecheck.behavior_detected.v1]
```

```yaml
# plugins/blink-jump/manifest.yaml
subscribes: [vision.signals.v1]
publishes:  [vision.request.v1]
```

Note that every consumer must declare `vision.request.v1` in `publishes` — publishing an
undeclared topic is a logged error and a dropped message, which here would silently mean
"vision never runs the model I need".

---

## 6. Vision internals

```
AVCaptureVideoDataOutput @ max(requested fps), capped at 30
  │
  ├─ frame due for face?  ──► VNDetectFaceLandmarks      ──┐
  ├─ frame due for hands? ──► VNDetectHumanHandPose      ──┤
  ├─ frame due for body?  ──► VNDetectHumanBodyPose      ──┼──► publish per topic
  ├─ frame due for seg?   ──► VNGeneratePersonSegmentation─┘
  │                                   │
  │                                   ▼
  │                              VCGeometry ──────────────► vision.signals.v1
  │
  └─ JPEG encode ──► /preview.mjpeg   (only while a browser is attached)
```

Three properties this must have:

- **Per-topic rates are independent.** postures at 2 fps must not drag body-pose inference
  to 60 because blink-jump wants faces fast.
- **Models are constructed lazily and released** when their topic's demand reaches zero. An
  idle `VNRequest` still holds resources.
- **The preview is encoded only while a client is attached.** JPEG encoding every frame for
  nobody is the second-largest avoidable cost after inference.

---

## 7. UI

Vision's tab is the preview, the camera picker, and an honest readout of what is running
and who asked for it. That readout **is** the privacy surface — one place that says "the
camera is on because postures wants body pose".

```
┌─ Vision ─────────────────────────────────┐
│  [ live preview + overlay of live tiers ] │
│  Camera: FaceTime HD Camera          ▾    │
│  ── Running now ───────────────────────   │
│  face   30fps  ← blink-jump, vibecheck    │
│  hands  15fps  ← vibecheck                │
│  body    2fps  ← postures                 │
└───────────────────────────────────────────┘
```

Vision has **no feature toggles**. The user turns features on in the plugin that owns the
feature; vision derives its models from live demand and never from a setting of its own.
The user never sees a "head landmarks" switch.

**v1 loses vibecheck's in-tab camera overlay.** A detector cannot embed
`/p/vision/preview.mjpeg` without an absolute cross-plugin URL, and the plugin HTTP contract
requires all URLs to be relative because the plugin must not know where it is mounted. One
preview, in vision's tab. Detector tabs become data and config only.

`GET /api/state` on vision reports the same readout as JSON, since `/api/*` is the real
interface and the HTML is its first consumer.

---

## 8. What moves

| From `plugins/vibecheck/` | To |
|---|---|
| `CameraSession.swift`, `VisionLandmarkExtractor.swift` | `plugins/vision/Sources/VisionKit/` |
| `JPEGEncoder.swift`, `PreviewStream.swift` | `plugins/vision/Sources/VisionKit/` |
| `Geometry.swift` → `ViewerSpace` | `plugins/vision/Sources/VCGeometry/` |
| `Geometry.swift` → `BFRBBehavior` | **stays** — a product noun, not geometry |
| `Geometry.swift` → `HandGeometry`, `FaceGeometry`, `HairMask`, `LandmarkFrame` | **deleted both sides**, replaced by the generated proto types of §4 |
| `Sources/VCPluginSDK/` | `sdk/swift/VCPluginSDK/` |
| `BFRBDetector`, `DetectionPolicy`, `DetectionEngine`, stores, alerts, `API` | **stays**, now fed by the bus |

Lifting `VCPluginSDK` out is not optional cleanup: vision, vibecheck and blink-jump all
need it, and a second copy is how the two disagreeing `Package.resolved` files already in
this tree came to exist. Each plugin's `Package.swift` takes a local path dependency.

`DetectionEngine.swift` is 856 lines owning capture, detection, alerting and SSE at once.
Losing capture is the natural moment to split it.

`BFRBDetector` needs face + hands + segmentation **from the same frame**, so vibecheck
joins the three topics by `Header.seq` and evaluates only on a complete set. A frame whose
segmentation was dropped for a slow subscriber is skipped, not evaluated with stale hair
data.

### 8.1 Camera permission is unaffected

The TCC grant is keyed to the **spawning process** — core — not to the plugin binary, and
the child's embedded `__info_plist` supplies only the prompt text. Moving capture from
`vibecheck` to `vision` therefore does not re-prompt and does not invalidate the grant.
`plugins/vision/` must embed `Info.plist` with `NSCameraUsageDescription` via
`-sectcreate __TEXT __info_plist`, **and that section is inert until an ad-hoc signature
seals it**. `vibecheck` drops both once it no longer touches the camera.

---

## 9. Testing

- **`VCGeometry` unit tests** against fixture landmark sets. EAR, yaw/pitch/roll and spine
  angle each have a right answer, which is test (3) of §2 doing its job.
- **Conformance clip.** One recorded video → vision → vibecheck, asserting **episode-level**
  agreement with today's behaviour: same behaviour detected, onset within ±250 ms.
  Landmark-level numeric agreement is not a valid target across model versions.
- **Bus latency spike, before committing to blink-jump.** Measure publish → deliver over the
  unix socket at 60 fps. A game has a 16 ms frame budget and nothing in-tree has measured
  this path. If it does not clear the budget, blink-jump's design changes, not vision's.
- **Demand and request behaviour**, as kernel-level tests: all consumers disabled closes the
  session; a consumer disappearing without retracting closes it by TTL; a request for one
  topic constructs exactly one model.
- **One e2e per plugin** against an in-process kernel, as `plugins/todo/` and
  `plugins/vibecheck/` already do. Test sockets under `os.MkdirTemp("/tmp", …)` — macOS caps
  `sockaddr_un.sun_path` at 104 bytes and `t.TempDir()` blows past it.

Prove each guard can fail before trusting it: break the thing, watch the test go red,
restore.

---

## 10. Kernel discipline

D10 still binds. No product noun — `vision`, `camera`, `face`, `posture`, `blink`,
`detection` — may appear in any `backend/kernel/*.go` file, comments and test fixtures
included. `TestKernelContainsNoProductNouns` fails the build.

**Nothing in this design requires a core change.** That is the load-bearing claim: if
implementation starts reaching for one, the design has drifted and the drift should be
examined rather than the kernel edited.

---

## 11. Deliberately deferred

`fps` in the kernel contract · publisher attribution on `Event` · cross-plugin preview
embedding · `vision-linux` / MediaPipe provider · two-handed detection (`extractHand` still
reads `results?.first` despite `maximumHandCount = 2`) · event-log persistence and replay ·
per-plugin origin isolation.

Each is addable without changing the contracts above.
