import Foundation
import VCPluginSDK

/// `fputs`, never `FileHandle.standardError.write(_:)` — the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown. An abort
/// there is charged as a failed start.
private func apiLog(_ message: String) {
    fputs("blink-jump: \(message)\n", stderr)
}

/// What `GET /api/state` answers.
///
/// `/api/*` is the real interface and the HTML is its first consumer — so this
/// is deliberately everything the page renders plus the diagnostics the page
/// cannot show, in one document a `curl` can read.
public struct BlinkJumpState: Encodable, Sendable {
    public var detector: BlinkEngine.Snapshot
    public var request: VisionRequester.Snapshot
    public var scores: BlinkJumpScores
    public var config: BlinkJumpConfig
    /// A plain-English reading of the two states above, because the single
    /// most likely way to wire this up wrong — subscribed, but the provider
    /// never heard the request — looks exactly like a working plugin from
    /// every other angle.
    public var note: String
}

/// Assembles the state document, including the diagnostic note.
///
/// Split out from the route so the sentence a player is shown when nothing
/// works is a value that can be reasoned about, not a string built inside a
/// closure inside an HTTP handler.
public func blinkJumpState(
    detector: BlinkEngine.Snapshot,
    request: VisionRequester.Snapshot,
    scores: BlinkJumpScores,
    config: BlinkJumpConfig,
    now: Date = Date()
) -> BlinkJumpState {
    BlinkJumpState(
        detector: detector,
        request: request,
        scores: scores,
        config: config,
        note: diagnosticNote(detector: detector, request: request, now: now)
    )
}

func diagnosticNote(
    detector: BlinkEngine.Snapshot,
    request: VisionRequester.Snapshot,
    now: Date
) -> String {
    if !request.hostAttached {
        return "Not connected to core yet."
    }
    // Ahead of everything else on purpose: `lastError` is cleared by the next
    // successful assertion, and the heartbeat asserts every 10 s — so a stale
    // one does not exist. If it is set, publishing is still failing right now,
    // and every state below it is a description of a request that never
    // reached the bus.
    if let last = request.lastError {
        return "The last request failed to publish (\(last)); the 10s heartbeat will retry."
    }
    if request.topics.isEmpty {
        return "Nobody is playing, so no camera has been requested. The provider closes the camera when the last request is retracted."
    }
    if request.providerSubscribers == 0 {
        return "Requesting \(VisionTopic.signals), but nothing subscribes to \(VisionTopic.request) — the vision plugin does not appear to be running."
    }
    guard let lastSignal = detector.lastSignalAt else {
        return "Requested \(VisionTopic.signals) and the provider is listening, but no signal has arrived yet."
    }
    if now.timeIntervalSince(lastSignal) > 3 {
        return "No signal for \(Int(now.timeIntervalSince(lastSignal)))s — the provider stopped publishing."
    }
    if !detector.tracking {
        return "Receiving signals, but no eye measurement in them — the face model is not running, or nobody is in frame."
    }
    return "Tracking. Blink to jump."
}

/// What the page POSTs when a run ends.
struct ScoreReport: Decodable {
    var score: Int
    /// Jumps in that run. Optional so an older page, or a hand-rolled `curl`,
    /// still records a score.
    var jumps: Int?
}

/// Wires the whole HTTP surface. Every dependency is passed in: this
/// function's job is connecting already-built pieces to paths, not deciding
/// how any of them are built.
///
/// Called BEFORE `VCHost.connect()`, always — core's proxy targets this
/// plugin's port the instant it marks it up, and `/api/state` is what any
/// client polls first to decide the plugin is reachable at all.
public func registerBlinkJumpRoutes(
    router: VCRouter,
    engine: BlinkEngine,
    requester: VisionRequester,
    config: ConfigStore,
    scores: ScoreStore,
    indexHTML: @escaping @Sendable () -> Data?
) async {
    await router.handle("/") { _, writer in
        guard let html = indexHTML() else {
            // A missing resource is a 500 an operator can see, never a process
            // exit: five unrequested exits park this plugin in StateFailed.
            apiLog("ui/index.html is missing from the resource bundle")
            try await writer.writeHead(status: 500, headers: ["Content-Type": "text/plain; charset=utf-8"])
            try await writer.write(Data("blink-jump: UI resources are missing from this install\n".utf8))
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
        let state = blinkJumpState(
            detector: await engine.snapshot(),
            request: await requester.snapshot(),
            scores: await scores.load(),
            config: await config.load()
        )
        try await respondJSON(writer, status: 200, state)
    }

    await router.handle("/api/config") { request, writer in
        switch request.method {
        case "GET":
            try await respondJSON(writer, status: 200, await config.load())

        case "PUT":
            guard let decoded = try? JSONDecoder.blinkJump().decode(BlinkJumpConfig.self, from: request.body) else {
                try await respondError(writer, status: 400, "invalid config")
                return
            }
            let saved: BlinkJumpConfig
            do {
                saved = try await config.save(decoded)
            } catch {
                // The error can carry this plugin's absolute data path, which
                // is not the caller's to see. Logged here, generic on the wire.
                apiLog("config save failed: \(error)")
                try await respondError(writer, status: 500, "internal error")
                return
            }
            // Apply the PERSISTED (clamped) value, never the raw decode, so
            // the running detector can never disagree with the file.
            await engine.apply(thresholds: saved.thresholds)
            await requester.setFPS(saved.fps)
            try await respondJSON(writer, status: 200, saved)

        default:
            try await respondMethodNotAllowed(writer, "GET, PUT")
        }
    }

    // Not in the minimum route list, but the game is unplayable without it:
    // the run happens in the browser, so the page is the only thing that knows
    // a run ended and what it scored.
    await router.handle("/api/score") { request, writer in
        guard request.method == "POST" else {
            try await respondMethodNotAllowed(writer, "POST")
            return
        }
        guard let report = try? JSONDecoder().decode(ScoreReport.self, from: request.body) else {
            try await respondError(writer, status: 400, "expected {\"score\": <int>}")
            return
        }
        do {
            let updated = try await scores.record(score: report.score, jumps: report.jumps ?? 0)
            try await respondJSON(writer, status: 200, updated)
        } catch {
            apiLog("score save failed: \(error)")
            try await respondError(writer, status: 500, "internal error")
        }
    }

    await router.handle("/api/events") { _, writer in
        try await writer.writeHead(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-store",
            "Connection": "keep-alive",
        ])
        // Attaching is what asks the provider for a camera; detaching is what
        // releases it. Holding this request `Task` open for the life of the
        // stream — rather than attaching and returning — is deliberate: a
        // write that throws is the ONLY way this process learns the tab
        // closed, and that write has to happen somewhere this handler can
        // catch it.
        let (id, stream) = await engine.attach()
        do {
            try await pump(stream, to: writer)
        } catch {
            await engine.detach(id)
            throw error
        }
        await engine.detach(id)
        try await writer.finish()
    }
}

// MARK: - SSE

/// Interleaves game events with a keep-alive comment.
///
/// The keep-alive is load-bearing, not politeness. Meter frames only flow
/// while the provider is publishing, so if vision is down this stream would go
/// completely silent — and a silent stream never writes, never fails, and
/// never tells this plugin that the tab was closed half an hour ago. The
/// camera would then stay requested for a player who left. The comment line
/// forces a write every few seconds, which is what makes `detach` happen.
private func pump(_ stream: AsyncStream<GameEvent>, to writer: any VCResponseWriter) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .meter(let meter):
                    try await writer.write(sseMessage(event: "meter", dto: meter))
                case .blink(let blink):
                    try await writer.write(sseMessage(event: "blink", dto: blink))
                }
            }
        }
        group.addTask {
            while true {
                try await Task.sleep(for: .seconds(5))
                try await writer.write(Data(": keep-alive\n\n".utf8))
            }
        }
        // Same shape as `VCHost.runOneSession`: whichever child finishes or
        // throws first decides the stream, and the loser is cancelled and
        // drained rather than leaked.
        let first = await group.nextResult()
        group.cancelAll()
        while await group.nextResult() != nil {}
        if case .failure(let error)? = first { throw error }
    }
}

private func sseMessage(event: String, dto: some Encodable) -> Data {
    let encoder = JSONEncoder.blinkJump()
    // Compact, always: a pretty-printed body contains newlines, and a newline
    // inside `data:` ends the SSE message early.
    encoder.outputFormatting = [.sortedKeys]
    let json = (try? encoder.encode(dto)) ?? Data("{}".utf8)
    var data = Data("event: \(event)\ndata: ".utf8)
    data.append(json)
    data.append(Data("\n\n".utf8))
    return data
}

// MARK: - Response helpers

private func respondJSON(_ writer: any VCResponseWriter, status: Int, _ value: some Encodable) async throws {
    let body = (try? JSONEncoder.blinkJump().encode(value)) ?? Data("{}".utf8)
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
