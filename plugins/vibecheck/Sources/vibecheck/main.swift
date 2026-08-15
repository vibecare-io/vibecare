import Foundation
import CoreVideo
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

// TEMPORARY, for Task 11/12 manual verification only. `AVCaptureSession` and
// Vision need real hardware and cannot be unit-tested, so this starts a real
// camera session, logs the first frame's dimensions and the per-frame
// `mirrored` flag, and exits — without touching `VCEnvironment`, since a
// manual `--probe-camera` run has none of core's spawn env vars set.
// Deliberately left in past this task rather than deleted: a human still
// needs to run it (the camera permission prompt, if any, needs a real click)
// and confirm the observations in the task report. Remove once that's done.
if CommandLine.arguments.contains("--probe-camera") {
    final class ProbeReceiver: CameraFrameReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<(Int, Int, Bool), Never>

        init(_ continuation: CheckedContinuation<(Int, Int, Bool), Never>) {
            self.continuation = continuation
        }

        func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            continuation.resume(returning: (width, height, mirrored))
        }
    }

    log("--probe-camera: starting camera session")
    let probeSession = CameraSession()
    // Kept alive for the duration of the probe: `CameraSession.receiver` is
    // `weak`, so nothing else retains this between assignment and the first
    // frame arriving on the camera's background queue.
    var probeReceiver: ProbeReceiver?

    switch await probeSession.start() {
    case .started:
        log("--probe-camera: session started, waiting for first frame...")
        let (width, height, mirrored) = await withCheckedContinuation { (k: CheckedContinuation<(Int, Int, Bool), Never>) in
            let receiver = ProbeReceiver(k)
            probeReceiver = receiver
            probeSession.receiver = receiver
        }
        log("--probe-camera: first frame \(width)x\(height) mirrored=\(mirrored)")
        _ = probeReceiver // keep the compiler from flagging the write-only retain above
    case .denied:
        log("--probe-camera: camera access denied")
    case .noDevice:
        log("--probe-camera: no camera device found")
    }
    probeSession.stop()
    exit(0)
}

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

let previewStream = PreviewStream()
let snoozeGate = SnoozeGate()
// Constructed hostless: routes (and the `DetectionEngine` they need to
// exist) must be registered before `VCHost.connect()` can be called at all
// — see the ordering comment below — so no live `VCHost` exists yet at this
// point. `hostSink.attach(host:)` runs right after `connect()` returns.
let hostSink = HostSink(prefs: alertPrefsStore, snooze: snoozeGate)
let engine = DetectionEngine(config: configStore, counts: countsStore,
                              sink: hostSink, previewStream: previewStream)

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
// the SSE event feed, the MJPEG preview, and the bundled behavior icons.
// Registered before `VCHost.connect()` below, same reasoning as `/` above:
// core's proxy targets this plugin's port the instant `connect()` marks it
// up, and `/api/state` in particular is what the e2e harness (and any real
// client) polls first to decide the plugin is reachable at all.
await registerVibeCheckRoutes(
    router: router,
    engine: engine,
    config: configStore,
    prefs: alertPrefsStore,
    preview: previewStream,
    sink: hostSink,
    snooze: snoozeGate,
    loadIcon: { id in uiResourceURL("ui/icons/\(id).svg").flatMap { try? Data(contentsOf: $0) } }
)

let host = try await VCHost.connect(env: env, router: router)

// Only now does a live `VCHost` exist for `HostSink.fired` to alert/publish
// through — see `HostSink`'s and `hostSink`'s own doc comments for why this
// can't happen any earlier.
await hostSink.attach(host: host)

// Registered immediately after connecting, not later: SIGTERM can land in
// the gap, and a hook registered after shutdown has already run is executed
// rather than dropped (the Go SDK's sync.Once silently loses it). Stops the
// camera on the way down — privacy-adjacent, same as every other path that
// turns detection off — via the same `stop()` this task's wiring fixed to
// coordinate with an in-flight camera start.
await host.onShutdown { await engine.stop() }

// Fire-and-forget, NOT awaited inline: `engine.start()` may await a TCC
// permission prompt (or, per `CameraSession.start()`, `AVCaptureDevice.
// requestAccess`) that can take arbitrarily long — or in a display-less
// environment, may not resolve promptly at all. Awaiting it here would
// block this script from ever reaching `waitForShutdown()` below, and
// `waitForShutdown()` returning is the ONLY way this process exits (see its
// own doc comment) — SIGTERM handling is independent (trapped inside
// `VCHost.connect()` already), but the process itself would never fall off
// the end and never actually terminate. `start()` internally loads
// `cachedConfig` from disk and only opens the camera if it says `enabled`,
// so a fresh/disabled install returns near-instantly regardless.
Task { await engine.start() }

// This — not a sleep, and not exit() — is how the process ends. VCHost's
// SIGTERM handler runs the shutdown hooks and deliberately does NOT call
// exit(), because supervisor.go cannot tell an SDK-initiated exit from a
// crash. Termination happens by this returning and main falling off the end.
// Park here forever instead and every shutdown costs core its full 5 s grace
// followed by a SIGKILL.
await host.waitForShutdown()
