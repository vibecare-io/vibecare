import Foundation
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file. Same
/// rule, same reason, as every other `fputs`-not-`FileHandle` comment in
/// this package.
private func apiLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// `/api/*` is the real interface; the HTML at `/` (registered separately,
/// in `main.swift`) is its first consumer. Keeping this surface complete and
/// honest is what lets a non-webview client (a TUI, say) drive this plugin
/// with no core change and no change here either.
///
/// Every dependency is passed in rather than constructed here: this
/// function's whole job is wiring already-built pieces (`DetectionEngine`,
/// the stores, `VisionFrameJoiner`, `HostSink`, `SnoozeGate`) to HTTP paths,
/// not deciding how any of them are built — that decision, and the process-
/// bundle-specific `loadIcon` closure in particular, belongs to `main.swift`.
///
/// ## What the vision cutover removed from this surface
///
/// `/preview.mjpeg` and the `frame` SSE event are both gone. There is one
/// preview now and it lives in the `vision` plugin's tab: a detector cannot
/// embed `/p/vision/preview.mjpeg` without an absolute cross-plugin URL, and
/// the plugin HTTP contract requires every URL to be relative because a
/// plugin must not know where it is mounted (design §7). What is left is
/// data and config — state, config, alert prefs, snooze, counts and the
/// `detection` SSE event — which is exactly what a detector tab is for.
///
/// Error discipline throughout, copied from `plugins/todo/main.go`'s
/// comments because they encode real rules: a caller's mistake (malformed
/// JSON, a missing/non-integer query parameter) gets a 400 with the
/// message; anything else (a store write failing) gets logged server-side
/// via `apiLog` and answered with a generic 500 — store errors can contain
/// the store's absolute filesystem path, which is not the client's to see.
public func registerVibeCheckRoutes(
    router: VCRouter,
    engine: DetectionEngine,
    config: ConfigStore,
    prefs: AlertPrefsStore,
    joiner: VisionFrameJoiner,
    sink: HostSink,
    snooze: SnoozeGate,
    loadIcon: @escaping @Sendable (String) -> Data?
) async {
    await router.handle("/api/state") { _, writer in
        var snapshot = await engine.snapshot()
        // Composed here rather than inside the engine: the engine decides
        // what a detection is, the joiner owns the subscription rule and the
        // only honest count of what actually arrived, and this route is the
        // one place that can see both. It is also the readout that answers
        // "detection is on but nothing happens" — a non-empty
        // `requiredTopics` with `joined == 0` means the provider is not
        // publishing what we asked for, which is otherwise indistinguishable
        // from a broken bus.
        snapshot.vision = await joiner.stats()
        try await respondJSON(writer, status: 200, snapshot)
    }

    await router.handle("/api/config") { request, writer in
        switch request.method {
        case "GET":
            try await respondJSON(writer, status: 200, await config.load())

        case "PUT":
            guard let decoded = try? JSONDecoder().decode(VibeCheckConfig.self, from: request.body) else {
                try await respondError(writer, status: 400, "invalid config")
                return
            }
            do {
                try await config.save(decoded)
            } catch {
                apiLog("config save failed: \(error)")
                try await respondError(writer, status: 500, "internal error")
                return
            }
            // "apply live": the persisted (clamped) value, not the raw
            // decode — `config.load()` returns exactly what `save` just
            // wrote, so the engine's in-memory state can never diverge from
            // what's on disk.
            let saved = await config.load()
            // Reserved HERE, synchronously, before responding or detaching
            // — see `DetectionEngine.nextApplyGeneration()`'s doc comment
            // for why this specific ordering (not inside the `Task` below)
            // is what makes "the last request wins" hold even though the
            // apply itself runs detached.
            let generation = await engine.nextApplyGeneration()
            try await respondJSON(writer, status: 200, saved)
            // Applied AFTER responding, in a DETACHED Task — never awaited
            // inline here. `apply` reaches `VisionRequest.publish`, a
            // deadlined RPC to core: it cannot block on a human the way the
            // pre-cutover TCC prompt could, but it can still take the full
            // 5s call deadline against a wedged core, and via
            // `VCHTTPServer`'s `lastRequestTask` chaining every LATER
            // request on the same keep-alive connection would queue behind
            // it. The response is already fully determined by `saved`,
            // which is already persisted, by this point.
            Task { await engine.apply(saved, generation: generation) }

        default:
            try await respondMethodNotAllowed(writer, "GET, PUT")
        }
    }

    // Ruling P4: both GET and POST, always — this is an alert-action target
    // (`HostSink.fired`'s "Turn off" button), and a client following an
    // action URL issues a GET; core's proxy does not rewrite methods.
    await router.handle("/api/config/disable") { request, writer in
        guard request.method == "GET" || request.method == "POST" else {
            try await respondMethodNotAllowed(writer, "GET, POST")
            return
        }
        var current = await config.load()
        current.enabled = false
        do {
            try await config.save(current)
        } catch {
            apiLog("config save failed: \(error)")
            try await respondError(writer, status: 500, "internal error")
            return
        }
        let saved = await config.load()
        // Same "reserve a generation before responding/detaching" reasoning
        // as `/api/config` PUT above — see `DetectionEngine
        // .nextApplyGeneration()`. A PUT racing this route on the same
        // connection (this route disabling right after a PUT that just
        // enabled) is exactly the ordering this guards against.
        let generation = await engine.nextApplyGeneration()
        try await respondJSON(writer, status: 200, saved)
        Task { await engine.apply(saved, generation: generation) }
    }

    // Ruling P4, same as above — "Snooze 10 min" is the other alert action.
    await router.handle("/api/snooze") { request, writer in
        guard request.method == "GET" || request.method == "POST" else {
            try await respondMethodNotAllowed(writer, "GET, POST")
            return
        }
        guard let raw = request.query["minutes"], let minutes = Int(raw) else {
            try await respondError(writer, status: 400, "minutes query parameter is required and must be an integer")
            return
        }
        await snooze.snooze(minutes: minutes)
        try await respondJSON(writer, status: 200, SnoozeStateDTO(snoozedUntil: await snooze.deadline()))
    }

    await router.handle("/api/alert-prefs") { request, writer in
        switch request.method {
        case "GET":
            try await respondJSON(writer, status: 200, await prefs.load())

        case "PUT":
            guard let decoded = try? JSONDecoder().decode([String: NotificationPreferences].self, from: request.body) else {
                try await respondError(writer, status: 400, "invalid alert preferences")
                return
            }
            do {
                try await prefs.save(decoded)
            } catch {
                apiLog("alert prefs save failed: \(error)")
                try await respondError(writer, status: 500, "internal error")
                return
            }
            try await respondJSON(writer, status: 200, await prefs.load())

        default:
            try await respondMethodNotAllowed(writer, "GET, PUT")
        }
    }

    await router.handlePrefix("/icons/") { request, writer in
        let requested = String(request.path.dropFirst("/icons/".count))
        let id = requested.hasSuffix(".svg") ? String(requested.dropLast(4)) : requested
        guard BFRBBehavior.allCases.contains(where: { $0.defaultIconId == id }),
              let data = loadIcon(id) else {
            try await writer.writeHead(status: 404, headers: [:])
            try await writer.finish()
            return
        }
        try await writer.writeHead(status: 200, headers: [
            "Content-Type": "image/svg+xml",
            "Content-Length": "\(data.count)",
        ])
        try await writer.write(data)
        try await writer.finish()
    }

    await router.handle("/api/events") { _, writer in
        try await writer.writeHead(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-store",
        ])
        // One stream now, not two raced against each other: the `frame`
        // event carried landmarks for the in-tab overlay, and that overlay
        // moved to vision's tab with the preview it drew on. What is left is
        // confirmed detections, which the page uses to bump today's counts
        // without waiting for the 4s state poll.
        try await pumpDetections(sink.events(), to: writer)
    }
}

// MARK: - /api/events pump

private func pumpDetections(_ stream: AsyncStream<DetectionBroadcast>, to writer: any VCResponseWriter) async throws {
    for await broadcast in stream {
        try Task.checkCancellation()
        try await writer.write(sseMessage(event: "detection", dto: DetectionEventDTO(broadcast)))
    }
}

private func sseMessage(event: String, dto: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []   // compact: no embedded newlines to break SSE framing
    let json = (try? encoder.encode(dto)) ?? Data(#"{}"#.utf8)
    var data = Data("event: \(event)\ndata: ".utf8)
    data.append(json)
    data.append(Data("\n\n".utf8))
    return data
}

// MARK: - DTOs

private struct DetectionEventDTO: Encodable {
    var behavior: String
    var count: Int
    var time: Double

    init(_ broadcast: DetectionBroadcast) {
        behavior = broadcast.behavior.rawValue
        count = broadcast.count
        time = broadcast.event.time
    }
}

private struct SnoozeStateDTO: Encodable {
    var snoozedUntil: Date?
}

// MARK: - Response helpers

private func respondJSON(_ writer: any VCResponseWriter, status: Int, _ value: some Encodable) async throws {
    let body = (try? JSONEncoder().encode(value)) ?? Data(#"{}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

private func respondError(_ writer: any VCResponseWriter, status: Int, _ message: String) async throws {
    let body = (try? JSONEncoder().encode(["error": message])) ?? Data(#"{"error":"unknown"}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

private func respondMethodNotAllowed(_ writer: any VCResponseWriter, _ allow: String) async throws {
    try await writer.writeHead(status: 405, headers: ["Allow": allow])
    try await writer.finish()
}
