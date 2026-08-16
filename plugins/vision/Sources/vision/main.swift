import Foundation
import VCGeometry
import VCKStubs
import VCPluginSDK
import VisionAPI
import VisionKit

// The vision provider's composition root
// (docs/superpowers/specs/2026-08-15-vision-provider-design.md).
//
// ORDER IS MANDATORY AND IS THE WHOLE POINT OF THIS FILE:
//
//   1. read the three spawn env vars
//   2. build the provider and register every route — including `/` and
//      `/api/*` — on the router
//   3. `VCHost.connect`, which installs `/health`, binds 127.0.0.1:0, BEGINS
//      ACCEPTING, and only then registers with core
//   4. start the provider's loops on core's event stream
//   5. park in `waitForShutdown()`
//
// Getting 2 and 3 the wrong way round does not fail loudly — it produces 502s
// from core's reverse proxy, because core targets this port the instant it
// marks the plugin up, and `health.go`'s prober fails a plugin whose `/health`
// arrived after registration. An honest "down" page would be better than
// either; a race that usually wins is worse than both.
//
// NOTHING HERE EXITS ON AN ERROR except a misconfigured spawn (below), where
// there is no core connection to degrade against. `supervisor.go` charges any
// unrequested exit as a failed start and five park the plugin in `StateFailed`
// until somebody restarts it by hand — over, say, a camera the user has not
// granted access to yet.

/// `fputs`, never `FileHandle.standardError.write(_:)`: the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown.
func log(_ message: String) {
    fputs("vision: \(message)\n", stderr)
}

let env: VCEnvironment
switch VCEnvironment.fromProcess() {
case .success(let e):
    env = e
case .failure(let err):
    // The ONE place exiting is correct: a misconfigured spawn, where there is
    // nothing to serve, nothing to retry, and no core connection to degrade
    // against.
    log("\(err)")
    exit(1)
}

// `RegisterReq.id` is `VCEnvironment.pluginID` verbatim — `VCHost` reads it
// from here and never derives it from the binary name or the directory. Core
// matches the registering id against its manifest scan and refuses anything
// else, so a mismatch is a plugin that connects and is never marked up.
log("starting as \(env.pluginID), data dir \(env.dataDir.path)")

// MARK: - The provider

// The signals tier (§4.2), wired in from `VCGeometry`. `VisionKit` deliberately
// owns no math and `VCGeometry` deliberately owns no capture, so this closure
// is the only place the two meet.
//
// `signalsBuilder` is a value, hoisted out of the closure so it is captured
// once rather than rebuilt per frame — and so the calibration constants in
// `HeadPoseModel` have exactly one instance a future recalibration can change.
let signalsBuilder = SignalsBuilder()

// Holds the `VCHost` once one exists. The provider must be built before the
// routes, the routes before `connect()`, and `connect()` is what produces a
// host — so the publish seam is necessarily filled in afterwards. See the
// type's own doc comment for why that ordering is not negotiable.
let publisher = VisionDeferredPublisher()

let provider = VisionProvider(
    publisher: publisher,
    signalsComputer: { bundle in
        // ABSENT IS NOT ZERO. Every field is left unset when the model feeding
        // it did not run: `SignalsBuilder` writes a field only when it has a
        // real value, and nothing here fills a gap with `0`. A consumer that
        // read an absent `ear_l` as `0.0` would see a permanently closed eye,
        // which is why `Signals` makes every field `optional` in the first
        // place.
        //
        // The face layout travels with the frame and is MEASURED from the
        // regions the detector returned — see `VisionFrameBundle.faceLayout`.
        // A `nil` layout leaves every face-derived signal absent rather than
        // indexing a constellation nobody validated.
        signalsBuilder.signals(header: bundle.header,
                               face: bundle.face,
                               faceLayout: bundle.faceLayout,
                               hands: bundle.hands,
                               body: bundle.body)
    }
)

// MARK: - Routes, BEFORE connect

let router = VCRouter()

// `/`, `/api/state`, `/api/devices`, `PUT /api/device`, `/preview.mjpeg` and
// `/api/events` — the whole §7 surface. The scaffold's own `/` and
// `/api/state` closures are gone: `VCRouter.handle` is last-registration-wins,
// so keeping them alongside this call would silently serve whichever ran
// second.
//
// `/health` is deliberately NOT among these. The SDK installs it inside
// `connect()`, and re-registering it here would shadow the probe core actually
// polls.
await registerVisionRoutes(
    router: router,
    state: ProviderStateSource(provider: provider),
    camera: ProviderCameraControl(provider: provider),
    preview: ProviderPreviewSink(preview: provider.preview),
    overlay: ProviderOverlaySource(provider: provider)
)

// MARK: - Connect

let host = try await VCHost.connect(env: env, router: router)
// Publishes made before this point had nowhere to go; the provider has been
// queueing them into a bounded stream and its pump drains them from here on.
// The camera cannot have opened yet either — capture starts only from a plan,
// and a plan needs a demand event that only arrives over this connection.
publisher.attach(host)
log("registered with core as \(host.id) on port \(await host.httpPort)")

// Registered immediately after connecting, not later: SIGTERM can land in the
// gap between `connect()` returning and this line, and a hook registered after
// shutdown has already run is executed rather than dropped.
//
// This hook is what turns the LED off promptly on quit. It is best-effort by
// construction — the hook drain budget is smaller than a wedged `Publish`
// deadline — but the camera close itself is local and does not depend on core
// answering.
await host.onShutdown { await provider.shutdown() }

// `/health` answers degraded, with a detail, when the provider has been asked
// for the camera and cannot have it. `setHealth` takes a SYNCHRONOUS closure
// and the snapshot is `async`, so the closure reads a cache that a slow poll
// refreshes — never `await`s, never blocks the prober.
//
// Core never restarts a degraded plugin (`health.go`: "a degraded process is
// alive and may hold unflushed state, so terminating it is a user decision"),
// so this is a readout, not a trigger. And core force-clears `detail` on any
// transition back to up, which is why the detail is only ever set alongside
// "degraded".
let health = VisionHealthCache()
await host.setHealth { health.current() }

// MARK: - Start

// The event stream is core's Register stream: `vision.request.v1` payloads and
// the reserved `_core.demand.v1` announcements, which is where both halves of
// the control plane come from. A clean END of this stream is not an error — it
// is how the SDK reports that the host is going down, and `runEventLoop` treats
// it as a shutdown signal rather than something to recover from. The SDK's own
// reconnect ladder handles a Register stream that merely dropped, without ever
// finishing this stream.
await provider.start(events: host.events())

// Refreshes the health cache off the provider's own snapshot. A separate slow
// loop rather than a hook on the capture path: health is polled on core's
// timer, not ours, and a probe must never be able to stall behind a frame.
let healthRefresh = Task {
    while !Task.isCancelled {
        health.update(from: await provider.snapshot())
        try? await Task.sleep(for: .seconds(5))
    }
}
await host.onShutdown { healthRefresh.cancel() }

// This — not a sleep and not `exit()` — is how the process ends: the SDK's
// SIGTERM handler runs the shutdown hooks and returns from here, `main` falls
// off the end, and the process exits normally. `supervisor.go` cannot tell an
// SDK-initiated `exit()` from a crash, so nothing in this tree calls it.
await host.waitForShutdown()
