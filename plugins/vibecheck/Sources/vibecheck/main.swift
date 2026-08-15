import Foundation
import VCPluginSDK

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

await router.handle("/api/state") { _, writer in
    // Task 8 replaces this with the detector's real state. Until then it is
    // still load-bearing: it is what the e2e harness polls to decide the
    // plugin is reachable through the proxy.
    let body = Data(#"{"running":false}"#.utf8)
    try await writer.writeHead(status: 200, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

let host = try await VCHost.connect(env: env, router: router)

// Registered immediately after connecting, not later: SIGTERM can land in
// the gap, and a hook registered after shutdown has already run is executed
// rather than dropped (the Go SDK's sync.Once silently loses it). Nothing to
// flush yet — the detector and the config store arrive in Tasks 8 and 10 —
// but the ordering is the part that has to be right from the start.
await host.onShutdown {}

// This — not a sleep, and not exit() — is how the process ends. VCHost's
// SIGTERM handler runs the shutdown hooks and deliberately does NOT call
// exit(), because supervisor.go cannot tell an SDK-initiated exit from a
// crash. Termination happens by this returning and main falling off the end.
// Park here forever instead and every shutdown costs core its full 5 s grace
// followed by a SIGKILL.
await host.waitForShutdown()
