import Testing
import Foundation
import VCPluginSDK
@testable import PosturesKit

// Exercises the route table `registerPostureRoutes` installs on a real
// `VCRouter`, entirely in-process — no HTTP socket, no live kernel. That is a
// deliberate, honest boundary: these prove the HANDLERS (status codes, JSON
// shapes, the GET-and-POST rule that alert actions depend on, the error
// discipline where a caller's mistake is a 400 with the message and anything
// else is a logged 500 that never leaks a store's filesystem path) wired to
// real, temp-directory-backed stores. What they do NOT prove is that NIO's
// framing or the kernel proxy deliver the same bytes end to end — that is an
// e2e test's job, against the actual built binary.

private actor RecordingWriter: VCResponseWriter {
    private(set) var status: Int?
    private(set) var headers: [String: String] = [:]
    private(set) var body = Data()
    private(set) var finished = false

    func writeHead(status: Int, headers: [String: String]) async throws {
        self.status = status
        self.headers = headers
    }

    func write(_ chunk: Data) async throws { body.append(chunk) }
    func finish() async throws { finished = true }
}

/// Parses the recorded body OUTSIDE the actor. `[String: Any]` is not
/// `Sendable`, so a `json()` method on `RecordingWriter` would not compile
/// under Swift 6 — the bytes cross the boundary, the parsed object does not.
private func decodeJSON(_ writer: RecordingWriter) async throws -> [String: Any] {
    let data = await writer.body
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct APIFixture {
    let router = VCRouter()
    let config: ConfigStore
    let snooze = SnoozeGate()
    let host = SpyHost()
    let monitor: PostureMonitor
    /// What `loadIcon` is allowed to find, so a 404 is provably about the
    /// allow-list and not about a missing file.
    static let iconBytes = Data("<svg/>".utf8)

    init() async throws {
        let dir = try tempDir()
        config = try ConfigStore(directory: dir)
        let counts = try NudgeCountsStore(directory: dir)
        let requester = VisionRequester(requester: "postures")
        monitor = PostureMonitor(config: config, counts: counts, snooze: snooze,
                                 requester: requester, initial: await config.load())
        await monitor.attach(host: host)
        await registerPostureRoutes(
            router: router,
            monitor: monitor,
            config: config,
            snooze: snooze,
            loadIcon: { id in id == PostureIcon.posture ? Self.iconBytes : nil }
        )
    }

    @discardableResult
    func call(_ method: String, _ path: String,
              query: [String: String] = [:], body: Data = Data()) async throws -> RecordingWriter {
        let handler = try #require(await router.route(path), "no route for \(path)")
        let writer = RecordingWriter()
        try await handler(VCRequest(method: method, path: path, query: query, body: body), writer)
        return writer
    }
}

// MARK: - The documented surface

@Test func everyDocumentedRouteIsRegistered() async throws {
    let f = try await APIFixture()
    for path in ["/api/state", "/api/config", "/api/config/disable",
                 "/api/snooze", "/icons/posture.svg"] {
        #expect(await f.router.route(path) != nil, "missing route \(path)")
    }
}

@Test func stateAnswersJSONWithTheKeysTheUIReads() async throws {
    let f = try await APIFixture()
    let writer = try await f.call("GET", "/api/state")
    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "application/json")
    #expect(await writer.finished)

    let object = try await decodeJSON(writer)
    for key in ["enabled", "config", "request", "verdict", "faults",
                "nudgesToday", "day", "frames", "notes"] {
        #expect(object[key] != nil, "missing \(key)")
    }
}

@Test func configRoundTripsThroughTheAPIAndIsAppliedLive() async throws {
    let f = try await APIFixture()
    var c = PostureConfig.default
    c.enabled = true
    c.dwell = 300
    let writer = try await f.call("PUT", "/api/config", body: try JSONEncoder().encode(c))
    #expect(await writer.status == 200)

    // The response is the PERSISTED value, and the monitor now agrees with it.
    let echoed = try await decodeJSON(writer)
    #expect(echoed["dwell"] as? Double == 300)
    #expect(await f.monitor.snapshot().enabled)
    // Enabling asserted the vision request rather than merely recording a
    // boolean — without this the plugin would receive nothing at all.
    #expect(await f.host.requests().last?.topics == VisionRequest.topics)

    let reread = try await f.call("GET", "/api/config")
    #expect(try await decodeJSON(reread)["dwell"] as? Double == 300)
}

@Test func configPUTClampsRatherThanAcceptingNonsense() async throws {
    let f = try await APIFixture()
    var c = PostureConfig.default
    c.dwell = 1
    c.cooldown = 1
    let writer = try await f.call("PUT", "/api/config", body: try JSONEncoder().encode(c))
    let echoed = try await decodeJSON(writer)
    // The echo is what the UI renders, so it has to be the clamped value —
    // silently snapping a field back with no visible change would look like
    // the save failed.
    #expect(echoed["dwell"] as? Double == 5)
    #expect(echoed["cooldown"] as? Double == 30)
}

@Test func aMalformedConfigBodyIsA400WithAReasonAndChangesNothing() async throws {
    let f = try await APIFixture()
    let writer = try await f.call("PUT", "/api/config", body: Data("{".utf8))
    #expect(await writer.status == 400)
    #expect(try await decodeJSON(writer)["error"] as? String == "invalid config")
    #expect(await f.config.load() == PostureConfig.default)
}

@Test func configRejectsMethodsItDoesNotImplement() async throws {
    let f = try await APIFixture()
    let writer = try await f.call("DELETE", "/api/config")
    #expect(await writer.status == 405)
    #expect(await writer.headers["Allow"] == "GET, PUT")
}

// MARK: - Alert-action targets

@Test func bothAlertActionTargetsAcceptAPlainGET() async throws {
    // A client following an `AlertAction.url` issues a GET, and core's proxy
    // does not rewrite methods. A POST-only handler here would mean the
    // buttons on the nudge do nothing at all.
    for (method, path, query) in [("GET", "/api/snooze", ["minutes": "30"]),
                                  ("POST", "/api/snooze", ["minutes": "30"]),
                                  ("GET", "/api/config/disable", [:]),
                                  ("POST", "/api/config/disable", [:])] {
        let f = try await APIFixture()
        let writer = try await f.call(method, path, query: query)
        #expect(await writer.status == 200, "\(method) \(path)")
    }
}

@Test func snoozeReportsItsDeadlineAndActuallyGates() async throws {
    let f = try await APIFixture()
    let writer = try await f.call("GET", "/api/snooze", query: ["minutes": "30"])
    #expect(try await decodeJSON(writer)["snoozedUntil"] != nil)
    #expect(await f.snooze.isActive())
}

@Test func timestampsGoOnTheWireAsISO8601StringsAndNotAsBareNumbers() async throws {
    // Measured against the running binary before this was pinned:
    // `JSONEncoder`'s default strategy sent `808532447.75` — seconds since
    // the 2001 reference date. `Date.parse` cannot read it, and a client that
    // passed it to `new Date(...)` would render a date in 1970.
    let f = try await APIFixture()
    let snoozed = try await decodeJSON(try await f.call("GET", "/api/snooze", query: ["minutes": "30"]))
    let deadline = try #require(snoozed["snoozedUntil"] as? String)
    #expect(ISO8601DateFormatter().date(from: deadline) != nil)

    let state = try await decodeJSON(try await f.call("GET", "/api/state"))
    #expect(state["snoozedUntil"] as? String != nil)
    #expect(state["snoozedUntil"] as? Double == nil)
}

@Test func snoozeWithoutAUsableMinutesParameterIsA400() async throws {
    let f = try await APIFixture()
    for query in [[:], ["minutes": "soon"]] as [[String: String]] {
        let writer = try await f.call("GET", "/api/snooze", query: query)
        #expect(await writer.status == 400)
        #expect(await f.snooze.isActive() == false)
    }
}

@Test func disableTurnsTheFeatureOffAndRetractsTheVisionRequest() async throws {
    let f = try await APIFixture()
    var on = PostureConfig.default
    on.enabled = true
    try await f.config.save(on)
    await f.monitor.apply(await f.config.load())
    #expect(await f.host.requests().last?.topics == VisionRequest.topics)

    let writer = try await f.call("GET", "/api/config/disable")
    #expect(await writer.status == 200)
    #expect(try await decodeJSON(writer)["enabled"] as? Bool == false)
    #expect(await f.config.load().enabled == false)
    // The whole point of the button: vision stops running the model.
    #expect(await f.host.requests().last?.topics.isEmpty == true)
}

@Test func snoozeAndDisableRejectOtherMethods() async throws {
    let f = try await APIFixture()
    for path in ["/api/snooze", "/api/config/disable"] {
        let writer = try await f.call("PUT", path)
        #expect(await writer.status == 405)
        #expect(await writer.headers["Allow"] == "GET, POST")
    }
}

// MARK: - The alert illustration

@Test func theIconTheAlertPointsAtIsActuallyServed() async throws {
    // A relative `svgPath` that fails to load downgrades the WHOLE alert to a
    // plain banner, taking the action buttons with it — losing a "Snooze"
    // button is a functional loss where losing a picture is cosmetic. So the
    // path on `PostureMonitor.appearance` and this route have to agree.
    let f = try await APIFixture()
    let path = try #require(PostureMonitor.appearance.svgPath)
    let writer = try await f.call("GET", "/" + path)
    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "image/svg+xml")
    #expect(await writer.body == APIFixture.iconBytes)
}

@Test func theIconRouteIsAnAllowListAndNotAFileReader() async throws {
    let f = try await APIFixture()
    for name in ["../../../etc/passwd", "posture.svg.bak", "anything"] {
        let writer = try await f.call("GET", "/icons/" + name)
        #expect(await writer.status == 404, "\(name) should not be served")
    }
}
