import Foundation
import VCPluginSDK
import PosturesKit

// Composition root. Order matters: routes before connect, because connect
// binds, accepts, and registers — and core's proxy targets our port the
// instant it marks us up.
//
// Postures is a pure CONSUMER of the vision provider: it reads
// vision.body_pose.v1 and vision.signals.v1 off the bus and publishes
// vision.request.v1 to say what it needs. It never opens a camera, which is
// why this package has no Info.plist, no -sectcreate and no codesign step.

/// `fputs`, never `FileHandle.standardError.write(_:)`: the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown.
func log(_ message: String) {
    fputs("postures: \(message)\n", stderr)
}

/// The packaged `ui/` directory, resolved WITHOUT `Bundle.module`.
///
/// SwiftPM's generated accessor is a `let` whose failure path is
/// `fatalError`, and a plugin that hard-aborts over a missing resource is
/// charged an unrequested exit by supervisor.go — five of those park it in
/// `StateFailed`. Resolve by hand and let a miss be a 500 an operator can see.
func uiResourceURL(_ relative: String) -> URL? {
    let base = Bundle.main.bundleURL
    let candidates = [
        // How `just build-postures-plugin` and `just install-plugins` lay it
        // out: the SwiftPM resource bundle next to the binary.
        base.appendingPathComponent("postures_postures.bundle").appendingPathComponent(relative),
        // A bare `ui/` dropped beside the binary, which is what someone
        // debugging an install reaches for first.
        base.appendingPathComponent(relative),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

let env: VCEnvironment
switch VCEnvironment.fromProcess() {
case .success(let e):
    env = e
case .failure(let err):
    // The ONE place exiting is correct: a misconfigured spawn, where there is
    // no core connection to degrade against.
    log("\(err)")
    exit(1)
}

// `VIBECARE_DATA_DIR` is created 0700 by core before spawn, so neither store
// has to create the directory — only open (or start fresh) the file inside
// it. A throw here would be a programming error, not a missing-file
// condition: both stores treat a missing or corrupt file as defaults.
let configStore = try ConfigStore(directory: env.dataDir)
let countsStore = try NudgeCountsStore(directory: env.dataDir)
let snoozeGate = SnoozeGate()

// `requester` is the plugin id core spawned us with, verbatim. The request
// topic is latest-wins PER REQUESTER and is not authenticated, so sending
// anything else would silently overwrite another consumer's request.
let requester = VisionRequester(requester: env.pluginID)
// Constructed hostless: routes — and the monitor they close over — must exist
// before `VCHost.connect()` can be called at all, so no live host exists yet.
// `attach(host:)` runs immediately after connect returns.
let monitor = PostureMonitor(
    config: configStore,
    counts: countsStore,
    snooze: snoozeGate,
    requester: requester,
    initial: await configStore.load()
)

let router = VCRouter()

await router.handle("/") { _, writer in
    guard let url = uiResourceURL("ui/index.html"), let html = try? Data(contentsOf: url) else {
        // Not fatal: a missing resource is a 500 an operator can see, never a
        // process exit. See uiResourceURL.
        log("ui/index.html is missing from the resource bundle")
        try await writer.writeHead(status: 500, headers: ["Content-Type": "text/plain; charset=utf-8"])
        try await writer.write(Data("postures: UI resources are missing from this install\n".utf8))
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

// The whole `/api/*` surface plus `/icons/`. Registered before connect, same
// reasoning as `/` above.
await registerPostureRoutes(
    router: router,
    monitor: monitor,
    config: configStore,
    snooze: snoozeGate,
    loadIcon: { id in uiResourceURL("ui/icons/\(id).svg").flatMap { try? Data(contentsOf: $0) } }
)

let host = try await VCHost.connect(env: env, router: router)

// Only now does a live `VCHost` exist for the monitor to alert through and
// for the requester to publish through.
await monitor.attach(host: host)

// Registered immediately after connecting, not later: SIGTERM can land in the
// gap, and a hook registered after shutdown has already run is executed
// rather than dropped. Retracting the vision request on the way down is
// privacy-adjacent — it is what lets vision destroy the body-pose model (and,
// if nobody else wants anything, close the camera) a beat before our
// subscription drops and the demand floor does it anyway.
await host.onShutdown { await monitor.stop() }

// Subscribed BEFORE the consuming task starts, so no event delivered between
// `connect()` and the first `for await` is lost — `events()` buffers 512.
let events = await host.events()

// Fire-and-forget: `start` consumes the event stream and never returns under
// normal operation, and `waitForShutdown()` returning is the ONLY way this
// process exits. Awaiting it inline would park main here instead and the
// process would never fall off the end.
Task { await monitor.start(events: events) }

// This — not a sleep, and not exit() — is how the process ends. VCHost's
// SIGTERM handler runs the shutdown hooks and deliberately does NOT call
// exit(), because supervisor.go cannot tell an SDK-initiated exit from a
// crash.
await host.waitForShutdown()
