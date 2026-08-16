import Foundation
import VCPluginSDK
import VibeCheckKit

// Composition root. Order matters: routes before connect, because connect
// binds, accepts, and registers — and core's proxy targets our port the
// instant it marks us up.

/// `fputs`, never `FileHandle.standardError.write(_:)` — the same rule, and
/// the same reason, as `VCPluginSDK/VCLog.swift` (whose `vcLog` is internal
/// to that module): the `FileHandle` overload raises an *uncatchable*
/// `NSException` on a closed descriptor, and core closes the plugin's stderr
/// pipe during its own shutdown. `supervisor.go` charges the resulting abort
/// as a failed start.
func log(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// The packaged `ui/` directory, resolved without touching `Bundle.module`.
///
/// SwiftPM's generated `Bundle.module` accessor is a `let` whose failure
/// path is `fatalError`, and its only shipping candidate is
/// `Bundle.main.bundleURL/vibecheck_vibecheck.bundle` — a sibling of the
/// binary. (Its other candidate is this machine's absolute `.build` path,
/// which exists on a developer box and nowhere else, so it would mask a
/// broken install right up until someone else ran it.) A plugin that
/// hard-aborts because a resource is missing is charged an unrequested exit
/// by `supervisor.go`, and five of those park it in `StateFailed` until a
/// manual dashboard restart. Resolve it by hand instead and let a miss be a
/// 500 the operator can see.
func uiResourceURL(_ relative: String) -> URL? {
    let base = Bundle.main.bundleURL
    let candidates = [
        // How `just build-vibecheck-plugin` and `just install-plugins` lay
        // it out: the SwiftPM bundle next to the binary.
        base.appendingPathComponent("vibecheck_vibecheck.bundle").appendingPathComponent(relative),
        // A bare `ui/` dropped beside the binary, which is what someone
        // debugging an install will reach for first.
        base.appendingPathComponent(relative),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

func uiIndexHTML() -> Data? {
    uiResourceURL("ui/index.html").flatMap { try? Data(contentsOf: $0) }
}

// The `--probe-camera` mode that used to live here is gone with the camera
// it probed. Its whole purpose was to answer, on real hardware, whether
// `AVCaptureConnection.isVideoMirrored` came back true for the built-in
// camera — a question that now belongs to `plugins/vision/`, which is the
// only process in this tree that opens a capture session.

let env: VCEnvironment
switch VCEnvironment.fromProcess() {
case .success(let e):
    env = e
case .failure(let err):
    // Nothing to serve and nothing to retry — this is a misconfigured spawn,
    // not a transient failure. This is the ONE place exiting is correct,
    // because there is no core connection to degrade against.
    log("\(err)")
    exit(1)
}

// `VIBECARE_DATA_DIR` is created 0700 by core before spawn, so this never
// has to create the directory itself — only open (or start fresh) the file
// inside it. A throw here is a programming error (a malformed URL), not a
// missing-file condition: ConfigStore/AlertPrefsStore/CountsStore all treat
// a missing or corrupt file as defaults rather than throwing.
let configStore = try ConfigStore(directory: env.dataDir)
let alertPrefsStore = try AlertPrefsStore(directory: env.dataDir)
let countsStore = try CountsStore(directory: env.dataDir)

let snoozeGate = SnoozeGate()
// Constructed hostless: routes (and the `DetectionEngine` they need to
// exist) must be registered before `VCHost.connect()` can be called at all
// — see the ordering comment below — so no live `VCHost` exists yet at this
// point. `hostSink.attach(host:)` and `visionRequest.attach(host:)` both run
// right after `connect()` returns.
let hostSink = HostSink(prefs: alertPrefsStore, snooze: snoozeGate)
let engine = DetectionEngine(config: configStore, counts: countsStore, sink: hostSink)

// The bus side: the joiner holds the seq join and the subscription rule,
// `visionRequest` decides what that rule is and tells the provider, and
// `intake` is the one loop that reads core's event stream.
let joiner = VisionFrameJoiner()
let visionRequest = VisionRequest(joiner: joiner)
let intake = VisionIntake(joiner: joiner, engine: engine, request: visionRequest)
await engine.attach(demand: visionRequest)

let router = VCRouter()

await router.handle("/") { _, writer in
    guard let html = uiIndexHTML() else {
        // Deliberately not a fatal error: see uiResourceURL.
        log("ui/index.html is missing from the resource bundle")
        try await writer.writeHead(status: 500, headers: ["Content-Type": "text/plain; charset=utf-8"])
        try await writer.write(Data("vibecheck: UI resources are missing from this install\n".utf8))
        try await writer.finish()
        return
    }
    try await writer.writeHead(status: 200, headers: [
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": "\(html.count)",
    ])
    try await writer.write(html)
    try await writer.finish()
}

// The whole `/api/*` surface — state, config, alert-prefs, snooze, disable,
// the SSE detection feed, and the bundled behavior icons. Registered before
// `VCHost.connect()` below, same reasoning as `/` above: core's proxy
// targets this plugin's port the instant `connect()` marks it up, and
// `/api/state` in particular is what the e2e harness (and any real client)
// polls first to decide the plugin is reachable at all.
await registerVibeCheckRoutes(
    router: router,
    engine: engine,
    config: configStore,
    prefs: alertPrefsStore,
    joiner: joiner,
    sink: hostSink,
    snooze: snoozeGate,
    loadIcon: { id in uiResourceURL("ui/icons/\(id).svg").flatMap { try? Data(contentsOf: $0) } }
)

let host = try await VCHost.connect(env: env, router: router)

// Only now does a live `VCHost` exist for `HostSink.fired` to alert/publish
// through, or for `VisionRequest` to publish `vision.request.v1` on — see
// their own doc comments for why this can't happen any earlier.
await hostSink.attach(host: host)
await visionRequest.attach(host: host)

// Registered immediately after connecting, not later: SIGTERM can land in
// the gap, and a hook registered after shutdown has already run is executed
// rather than dropped (the Go SDK's sync.Once silently loses it).
//
// Two hooks, in the order that matters to a user: retract the vision
// request first, so the provider tears down the models — and, if we were
// the last consumer, closes the camera and the LED — at once instead of
// 30 s later when our request's TTL lapses; then stop the engine so a frame
// still in flight cannot fire an alert on the way down. They run
// CONCURRENTLY under one shared budget (see `VCHost.drainShutdownHooks`),
// which is fine: neither depends on the other, and `stop()` makes the
// engine refuse frames regardless of whether the retraction landed.
await host.onShutdown { await visionRequest.retract() }
await host.onShutdown { await engine.stop() }

// The single reader of core's event stream: bus payloads into the join and
// on to the detector, `_core.demand.v1` into a re-assertion of our vision
// request. Started before `engine.start()` so that a frame arriving in
// response to the very first request has somewhere to land.
let events = await host.events()
Task { await intake.run(events) }

// Fire-and-forget, NOT awaited inline: `start()` reads config and counts off
// disk and then publishes `vision.request.v1`, and that publish is a
// deadlined RPC that can take up to 5 s against a core that is not answering
// yet. Awaiting it here would block this script from reaching
// `waitForShutdown()` below, and `waitForShutdown()` returning is the ONLY
// way this process exits (see its own doc comment) — the process would never
// fall off the end and never actually terminate.
Task { await engine.start() }

// This — not a sleep, and not exit() — is how the process ends. VCHost's
// SIGTERM handler runs the shutdown hooks and deliberately does NOT call
// exit(), because supervisor.go cannot tell an SDK-initiated exit from a
// crash. Termination happens by this returning and main falling off the end.
// Park here forever instead and every shutdown costs core its full 5 s grace
// followed by a SIGKILL.
await host.waitForShutdown()
