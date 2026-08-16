// Composition root for blink-jump — the design's proof that a consumer of the
// vision provider can be tiny. It subscribes to exactly one topic
// (`vision.signals.v1`), never sees a landmark, and never opens a camera.
//
// Order matters: routes are registered BEFORE `VCHost.connect()`, because
// connect binds, accepts and registers — and core's proxy targets this port
// the instant it marks the plugin up.

import Foundation
import VCPluginSDK
import BlinkJumpKit

/// `fputs`, never `FileHandle.standardError.write(_:)`: the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown.
func log(_ message: String) {
    fputs("blink-jump: \(message)\n", stderr)
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
        // How `just build-blink-jump-plugin` and `just install-plugins` lay it
        // out: the SwiftPM resource bundle next to the binary.
        base.appendingPathComponent("blink-jump_blink-jump.bundle").appendingPathComponent(relative),
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
// has to create the directory — only open, or start fresh from, the file
// inside it. Neither throws on a missing or corrupt file.
let configStore = ConfigStore(directory: env.dataDir)
let scoreStore = ScoreStore(directory: env.dataDir)
let startupConfig = await configStore.load()

// Constructed hostless: routes (and everything they need) must exist before
// `VCHost.connect()` can be called at all, so there is no live host yet.
// `requester.attach(publisher:)` runs the moment `connect()` returns.
let requester = VisionRequester(requester: env.pluginID, fps: startupConfig.fps)
let engine = BlinkEngine(thresholds: startupConfig.thresholds, requester: requester)

let router = VCRouter()
await registerBlinkJumpRoutes(
    router: router,
    engine: engine,
    requester: requester,
    config: configStore,
    scores: scoreStore,
    indexHTML: { uiResourceURL("ui/index.html").flatMap { try? Data(contentsOf: $0) } }
)

let host = try await VCHost.connect(env: env, router: router)

// Registered immediately after connecting, not later: SIGTERM can land in the
// gap, and `VCHost.onShutdown` runs a hook registered after shutdown already
// happened rather than dropping it.
await host.onShutdown {
    await engine.stop()
    await requester.stop()
}

// The bus loop. Two topics arrive here and nothing else:
//
//   * `vision.signals.v1` — the measurements. Note that an EMPTY signals
//     message is a valid statement ("nothing measured") and is handled inside
//     the engine as ABSENT, which pauses the game. It is not a shut eye.
//   * `_core.demand.v1` — reserved, delivered because this plugin declares
//     `vision.request.v1` under `publishes`. Core announces it on every
//     `Subscribe`, which makes it the reconnect signal the request lifecycle
//     re-asserts on.
//
// Detached rather than awaited: `waitForShutdown()` below is the only thing
// that ends this process, and this stream only finishes when the host stops.
let events = await host.events()
Task {
    for await event in events {
        switch event.topic {
        case VisionTopic.signals:
            await engine.ingest(payload: event.payload)
        case VCTopicDemand:
            guard let demand = VCDemandReading.decode(event.payload) else { continue }
            await requester.noteDemand(demand)
        default:
            break
        }
    }
}

// Publishing becomes possible only now, so this is where the request lifecycle
// starts: it asserts the current intent (with nobody playing, that is the
// empty retraction — the camera stays off until a tab opens) and starts the
// 10 s heartbeat.
await requester.attach(publisher: HostPublisher(host: host))
await engine.start()

log("registered with core as \(host.id); subscribed to \(VisionTopic.signals)")

// Termination happens by this returning and main falling off the end — not by
// exit(), which supervisor.go cannot tell from a crash.
await host.waitForShutdown()
