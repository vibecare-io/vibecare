import CoreGraphics
import Foundation
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file. Same
/// rule, same reason, as every other `fputs`-not-`FileHandle` comment in
/// this package (see `DetectionEngine.swift`'s `engineLog`, which this
/// mirrors rather than reuses — that one is `private` to its file).
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
/// the stores, `PreviewStream`, `HostSink`, `SnoozeGate`) to HTTP paths, not
/// deciding how any of them are built — that decision, and the process-
/// bundle-specific `loadIcon` closure in particular, belongs to `main.swift`.
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
    preview: PreviewStream,
    sink: HostSink,
    snooze: SnoozeGate,
    loadIcon: @escaping @Sendable (String) -> Data?
) async {
    await router.handle("/api/state") { _, writer in
        let snapshot = await engine.snapshot()
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
            try await respondJSON(writer, status: 200, saved)
            // Applied AFTER responding, in a DETACHED Task — never awaited
            // inline here. `engine.apply(_:)` can call `startCameraOnly()`
            // -> `camera.start()` -> `AVCaptureDevice.requestAccess`, which
            // does not return until a human answers a real system TCC
            // dialog (or, in a display-less environment, may never resolve
            // promptly at all). The HTTP response is already fully
            // determined by `saved`, which is already persisted, by this
            // point — nothing about it depends on the camera. Awaiting
            // `apply` inline would hang this response on first run, and
            // via `VCHTTPServer`'s `lastRequestTask` chaining (every
            // request on one keep-alive connection awaits the previous
            // one's `Task` before it can even start), every LATER request
            // queued behind it on the same connection would hang too.
            Task { await engine.apply(saved) }

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
        try await respondJSON(writer, status: 200, saved)
        // Same "respond first, apply in a detached Task" reasoning as
        // `/api/config` PUT above. `apply` transitioning to `enabled: false`
        // only ever calls the non-blocking `stop()` (no TCC prompt on the
        // way down), so this specific call could safely be awaited inline
        // today — but doing it the same way as PUT keeps this route from
        // silently growing that risk if `apply`'s shape ever changes, and
        // means neither route depends on reasoning about which direction
        // is "safe" to block on.
        Task { await engine.apply(saved) }
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

    await router.handle("/preview.mjpeg") { _, writer in
        // Attach-and-return, deliberately: `PreviewStream` owns the writer
        // from here on and drives it from the camera's own frame callback
        // (`DetectionEngine.didOutput`), independent of this request's
        // `Task`. This is what lets many concurrent viewers share one
        // upstream camera — each `attach` would otherwise have to block its
        // own request `Task` forever, which cannot work for a fan-out design
        // fed from outside the request. One consequence (see the task
        // report): this request's `VCHTTPHandler` `Task` completes
        // immediately, so a LATER pipelined request on the same keep-alive
        // connection is no longer serialized behind this stream's writes —
        // RFC 7230 ordering holds for every other route in this plugin
        // (each blocks for its own duration, per `VCHTTPServer.swift`'s
        // `lastRequestTask` chaining) but not for this one. No mainstream
        // client pipelines, so this is a known, accepted gap, not a bug.
        await preview.attach(writer)
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
        // Same shape as `VCHost.runOneSession`: two children race, whichever
        // finishes (or throws) first wins, and the other is cancelled and
        // drained rather than left running. `AsyncStream.Iterator.next()` is
        // documented to return `nil` promptly once its task is cancelled, so
        // `group.cancelAll()` genuinely unblocks whichever child is still
        // waiting on its stream instead of leaking it.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await pumpFrames(engine.frames(), to: writer) }
            group.addTask { try await pumpDetections(sink.events(), to: writer) }
            let first = await group.nextResult()
            group.cancelAll()
            while await group.nextResult() != nil {}
            if case .failure(let error)? = first { throw error }
        }
    }
}

// MARK: - /api/events pumps

private func pumpFrames(_ stream: AsyncStream<LandmarkFrame>, to writer: any VCResponseWriter) async throws {
    for await frame in stream {
        try Task.checkCancellation()
        try await writer.write(sseMessage(event: "frame", dto: FrameEventDTO(frame)))
    }
}

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
//
// `LandmarkFrame`/`BFRBEvent`/`DetectionBroadcast` are deliberately not
// `Codable` themselves (see `Geometry.swift`/`BFRBDetector.swift`) — they are
// this plugin's internal, viewer-space-but-not-wire-format representation.
// These are the wire shapes `/api/events` actually emits.

private struct FrameEventDTO: Encodable {
    struct Point: Encodable { var x: Double; var y: Double }
    struct Rect: Encodable { var x: Double; var y: Double; var width: Double; var height: Double }
    struct Face: Encodable { var box: Rect; var nose: Point; var mouth: Point }

    var seq: UInt64
    var ts: Double
    var mirrored: Bool
    var imageWidth: Double
    var imageHeight: Double
    var fingertips: [Point]
    var face: Face?

    init(_ frame: LandmarkFrame) {
        seq = frame.seq
        ts = frame.ts.timeIntervalSince1970
        mirrored = frame.mirrored
        imageWidth = Double(frame.imageSize.width)
        imageHeight = Double(frame.imageSize.height)
        fingertips = (frame.hand?.fingertips ?? []).map { Point(x: Double($0.x), y: Double($0.y)) }
        face = frame.face.map {
            Face(box: Rect(x: Double($0.box.minX), y: Double($0.box.minY),
                            width: Double($0.box.width), height: Double($0.box.height)),
                 nose: Point(x: Double($0.nose.x), y: Double($0.nose.y)),
                 mouth: Point(x: Double($0.mouth.x), y: Double($0.mouth.y)))
        }
    }
}

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
