import Foundation
import VCPluginSDK

/// `/api/*` is the real interface; the HTML at `/` (registered in
/// `main.swift`) is its first consumer. Keeping this surface complete and
/// honest is what lets a TUI or CLI drive this plugin later with no core
/// change and no change here.
///
/// Every dependency is passed in rather than constructed: this function's job
/// is wiring already-built pieces to paths, not deciding how they are built.
/// The process-bundle-specific `loadIcon` closure in particular belongs to
/// `main.swift`, which is the only place that knows how this binary was
/// staged.
///
/// Error discipline: a caller's mistake (malformed JSON, a missing or
/// non-integer query parameter) gets a 400 carrying the reason; anything else
/// (a store write failing) is logged server-side and answered with a generic
/// 500 — store errors quote the store's absolute filesystem path, which is
/// not the client's to see.
public func registerPostureRoutes(
    router: VCRouter,
    monitor: PostureMonitor,
    config: ConfigStore,
    snooze: SnoozeGate,
    loadIcon: @escaping @Sendable (String) -> Data?
) async {
    await router.handle("/api/state") { _, writer in
        try await respondJSON(writer, status: 200, await monitor.snapshot())
    }

    await router.handle("/api/config") { request, writer in
        switch request.method {
        case "GET":
            try await respondJSON(writer, status: 200, await config.load())

        case "PUT":
            guard let decoded = try? JSONDecoder().decode(PostureConfig.self, from: request.body) else {
                try await respondError(writer, status: 400, "invalid config")
                return
            }
            do {
                try await config.save(decoded)
            } catch {
                posturesLog("config save failed: \(error)")
                try await respondError(writer, status: 500, "internal error")
                return
            }
            // Apply the PERSISTED (clamped) value, never the raw decode, so
            // the monitor's in-memory config can never diverge from the file.
            let saved = await config.load()
            await monitor.apply(saved)
            try await respondJSON(writer, status: 200, saved)

        default:
            try await respondMethodNotAllowed(writer, "GET, PUT")
        }
    }

    // GET as well as POST, always: this is an alert-action target ("Turn
    // off"), and a client following an action URL issues a GET. Core's proxy
    // does not rewrite methods.
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
            posturesLog("config save failed: \(error)")
            try await respondError(writer, status: 500, "internal error")
            return
        }
        let saved = await config.load()
        // Awaited inline, unlike vibecheck's equivalent: `apply` here only
        // publishes one small bus message with a 5 s deadline on it. There is
        // no camera to open and no TCC prompt to wait on, so nothing can hold
        // this response — or the requests queued behind it on the same
        // keep-alive connection — open indefinitely.
        await monitor.apply(saved)
        try await respondJSON(writer, status: 200, saved)
    }

    // GET as well as POST, same reason: "Snooze 30 min" is the other alert
    // action.
    await router.handle("/api/snooze") { request, writer in
        guard request.method == "GET" || request.method == "POST" else {
            try await respondMethodNotAllowed(writer, "GET, POST")
            return
        }
        guard let raw = request.query["minutes"], let minutes = Int(raw) else {
            try await respondError(writer, status: 400,
                                   "minutes query parameter is required and must be an integer")
            return
        }
        await snooze.snooze(minutes: minutes)
        try await respondJSON(writer, status: 200, SnoozeStateDTO(snoozedUntil: await snooze.deadline()))
    }

    // The alert's illustration, fetched back through core's proxy from the
    // relative `svgPath` on `PostureMonitor.appearance`. A relative path that
    // fails to load downgrades the WHOLE alert to a plain banner, taking the
    // action buttons with it, so this route existing is not cosmetic.
    await router.handlePrefix("/icons/") { request, writer in
        let requested = String(request.path.dropFirst("/icons/".count))
        let id = requested.hasSuffix(".svg") ? String(requested.dropLast(4)) : requested
        // Allow-list, not a path join: `loadIcon` resolves against the
        // resource bundle, and handing it an attacker-chosen relative path
        // would turn this route into an arbitrary-file reader.
        guard PostureIcon.all.contains(id), let data = loadIcon(id) else {
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
}

/// The icons this plugin ships in `ui/icons/`. An explicit set rather than a
/// directory listing, so `/icons/` can never be talked into serving something
/// that merely happens to be next to them.
public enum PostureIcon {
    public static let posture = "posture"
    public static let all: Set<String> = [posture]
}

struct SnoozeStateDTO: Encodable {
    var snoozedUntil: Date?
}

// MARK: - Response helpers

/// The one encoder every `/api/*` response goes through.
///
/// `.iso8601`, NOT the default. `JSONEncoder`'s default `.deferredToDate`
/// writes a `Date` as seconds since the 2001 reference date — a bare number
/// that `Date.parse` in `index.html` cannot read at all, and that a JS client
/// naively passing to `new Date(...)` would silently interpret as
/// milliseconds since 1970 and render as a date in 1970. Measured against the
/// running binary: `snoozedUntil` came back as `808532447.75`. Every timestamp
/// on this surface (`snoozedUntil`, `lastNudgeAt`, `reading.at`,
/// `request.lastAssertedAt`) is a string a client can parse without knowing
/// anything about Foundation.
private func apiEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

func respondJSON(_ writer: any VCResponseWriter, status: Int, _ value: some Encodable) async throws {
    let body = (try? apiEncoder().encode(value)) ?? Data(#"{}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

func respondError(_ writer: any VCResponseWriter, status: Int, _ message: String) async throws {
    let body = (try? JSONEncoder().encode(["error": message])) ?? Data(#"{"error":"unknown"}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

func respondMethodNotAllowed(_ writer: any VCResponseWriter, _ allow: String) async throws {
    try await writer.writeHead(status: 405, headers: ["Allow": allow])
    try await writer.finish()
}
