import Testing
import Foundation
import VCPluginSDK
@testable import VibeCheckKit

// Exercises the `/api/*` route table `registerVibeCheckRoutes` installs on a
// real `VCRouter`, entirely in-process — no HTTP socket, no live kernel.
// That is a deliberate, honest boundary: these tests prove the HANDLERS
// (status codes, JSON shapes, the error discipline copied from
// `plugins/todo/main.go` — a caller's mistake is a 400 with the message,
// anything else is a logged 500 that never leaks a store's filesystem path)
// wired to real, temp-directory-backed stores. What they do NOT prove is
// that NIO's real HTTP framing, or the kernel proxy, deliver those same
// bytes end to end — that is `e2e_test.go`'s job, against the actual built
// binary. Neither test the camera or Vision: every fixture below uses
// `enabled: false`, deliberately, because a body with `enabled: true`
// reaching the `/api/config` PUT handler would call `DetectionEngine.apply`
// -> `camera.start()` -> real `AVFoundation`/TCC — undesirable and
// non-deterministic inside `swift test`, which (unlike the built binary
// `e2e_test.go` compiles) carries no `NSCameraUsageDescription`.

// MARK: - Fixtures

private actor RecordingWriter: VCResponseWriter {
    private(set) var status: Int?
    private(set) var headers: [String: String] = [:]
    private(set) var body = Data()
    private(set) var finished = false
    var failNextWrite = false

    func writeHead(status: Int, headers: [String: String]) async throws {
        self.status = status
        self.headers = headers
    }

    func write(_ chunk: Data) async throws {
        if failNextWrite { throw RecordingWriterError.boom }
        body.append(chunk)
    }

    func finish() async throws {
        finished = true
    }

    func setFailNextWrite(_ value: Bool) {
        failNextWrite = value
    }
}

private enum RecordingWriterError: Error { case boom }

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private struct Fixture {
    let router = VCRouter()
    let config: ConfigStore
    let prefs: AlertPrefsStore
    let counts: CountsStore
    let preview = PreviewStream()
    let snooze = SnoozeGate()
    let sink: HostSink
    let engine: DetectionEngine

    static func make() async throws -> Fixture {
        let dir = try tempDir()
        let config = try ConfigStore(directory: dir)
        let prefs = try AlertPrefsStore(directory: dir)
        let counts = try CountsStore(directory: dir)
        let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
        let engine = DetectionEngine(config: config, counts: counts, prefs: prefs, sink: sink)
        let f = Fixture(config: config, prefs: prefs, counts: counts, sink: sink, engine: engine)
        await registerVibeCheckRoutes(
            router: f.router, engine: f.engine, config: f.config, prefs: f.prefs,
            preview: f.preview, sink: f.sink, snooze: f.snooze,
            loadIcon: { id in id == "nail-biting" ? Data("<svg/>".utf8) : nil }
        )
        return f
    }

    /// `Fixture.make()` builds its own private `HostSink`/`SnoozeGate` pair
    /// for `sink`/`snooze`'s stored properties, but registers the routes
    /// against the ones actually passed to `registerVibeCheckRoutes` above
    /// — kept as separate `let`s (`self.snooze`, not the one baked into
    /// `sink`) is intentional: it is the same instance the router closures
    /// capture, so tests can drive it directly.
    init(config: ConfigStore, prefs: AlertPrefsStore, counts: CountsStore, sink: HostSink, engine: DetectionEngine) {
        self.config = config
        self.prefs = prefs
        self.counts = counts
        self.sink = sink
        self.engine = engine
    }
}

private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data = Data()) -> VCRequest {
    VCRequest(method: method, path: path, query: query, body: body)
}

// MARK: - /api/state

@Test func stateAlwaysReportsAPermissionString() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/state"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/api/state"), writer)

    #expect(await writer.status == 200)
    let decoded = try JSONDecoder().decode(EngineSnapshot.self, from: await writer.body)
    #expect(decoded.permission.isEmpty == false)
    #expect(decoded.running == false)
}

// MARK: - /api/config

@Test func configPutRejectsMalformedJSONWith400() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/config"))
    let writer = RecordingWriter()
    try await handler(request("PUT", "/api/config", body: Data("{not json".utf8)), writer)
    #expect(await writer.status == 400)
}

@Test func configPutPersistsAndClampsThenGetReflectsIt() async throws {
    let f = try await Fixture.make()
    let putHandler = try #require(await f.router.route("/api/config"))
    let body = """
    {"enabled":false,"sensitivity":5.0,"dwell":0.15,"cooldown":900,"enabledBehaviors":[]}
    """
    try await putHandler(request("PUT", "/api/config", body: Data(body.utf8)), RecordingWriter())

    let getHandler = try #require(await f.router.route("/api/config"))
    let getWriter = RecordingWriter()
    try await getHandler(request("GET", "/api/config"), getWriter)
    let decoded = try JSONDecoder().decode(VibeCheckConfig.self, from: await getWriter.body)
    #expect(decoded.sensitivity == 1.0)
    #expect(decoded.cooldown == 30)

    // Also confirms "apply live": the engine's own cached snapshot reflects
    // the same clamped values, not just what's on disk.
    let snap = await f.engine.snapshot()
    #expect(snap.config.sensitivity == 1.0)
}

@Test func configRejectsUnsupportedMethodWith405() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/config"))
    let writer = RecordingWriter()
    try await handler(request("DELETE", "/api/config"), writer)
    #expect(await writer.status == 405)
}

// MARK: - /api/config/disable — ruling P4: GET and POST both work

@Test(arguments: ["GET", "POST"])
func disableAcceptsBothGetAndPostAndTurnsDetectionOff(method: String) async throws {
    let f = try await Fixture.make()
    // Seed as enabled so there is something to observe turning off. Applying
    // this directly (not through the camera-touching PUT handler) keeps this
    // test off real AVFoundation entirely.
    var c = VibeCheckConfig.default
    c.enabled = true
    try await f.config.save(c)

    let handler = try #require(await f.router.route("/api/config/disable"))
    let writer = RecordingWriter()
    try await handler(request(method, "/api/config/disable"), writer)

    #expect(await writer.status == 200)
    #expect(await f.config.load().enabled == false)
}

// MARK: - /api/snooze — ruling P4: GET and POST both work

@Test(arguments: ["GET", "POST"])
func snoozeAcceptsBothGetAndPostAndSetsADeadline(method: String) async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/snooze"))
    let writer = RecordingWriter()
    try await handler(request(method, "/api/snooze", query: ["minutes": "10"]), writer)

    #expect(await writer.status == 200)
    #expect(await f.snooze.isActive() == true)
}

@Test func snoozeWithoutMinutesIs400() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/snooze"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/api/snooze"), writer)
    #expect(await writer.status == 400)
}

@Test func snoozeWithNonIntegerMinutesIs400() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/snooze"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/api/snooze", query: ["minutes": "soon"]), writer)
    #expect(await writer.status == 400)
}

// MARK: - /api/alert-prefs

@Test func alertPrefsPutRejectsMalformedJSONWith400() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/api/alert-prefs"))
    let writer = RecordingWriter()
    try await handler(request("PUT", "/api/alert-prefs", body: Data("nope".utf8)), writer)
    #expect(await writer.status == 400)
}

@Test func alertPrefsRoundTripsThroughPutAndGet() async throws {
    let f = try await Fixture.make()
    var prefs = await f.prefs.load()
    prefs["nailBiting"]?.title = "Custom title"
    let body = try JSONEncoder().encode(prefs)

    let putHandler = try #require(await f.router.route("/api/alert-prefs"))
    try await putHandler(request("PUT", "/api/alert-prefs", body: body), RecordingWriter())

    let getHandler = try #require(await f.router.route("/api/alert-prefs"))
    let getWriter = RecordingWriter()
    try await getHandler(request("GET", "/api/alert-prefs"), getWriter)
    let decoded = try JSONDecoder().decode([String: NotificationPreferences].self, from: await getWriter.body)
    #expect(decoded["nailBiting"]?.title == "Custom title")
}

// MARK: - /preview.mjpeg

@Test func previewRouteAttachesToThePreviewStream() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/preview.mjpeg"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/preview.mjpeg"), writer)

    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "multipart/x-mixed-replace; boundary=vcframe")
    #expect(await f.preview.writerCount == 1)
}

// MARK: - /icons/<id>.svg

@Test func iconRouteServesAKnownBundledIcon() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/icons/nail-biting.svg"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/icons/nail-biting.svg"), writer)
    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "image/svg+xml")
    #expect(await writer.body == Data("<svg/>".utf8))
}

@Test func iconRoute404sForAnUnknownID() async throws {
    let f = try await Fixture.make()
    let handler = try #require(await f.router.route("/icons/not-a-real-icon.svg"))
    let writer = RecordingWriter()
    try await handler(request("GET", "/icons/not-a-real-icon.svg"), writer)
    #expect(await writer.status == 404)
}

// MARK: - /api/events (SSE)
//
// The handler blocks for the connection's lifetime (it iterates a merged
// stream of `engine.frames()` and `sink.events()` directly, unlike
// `/preview.mjpeg`'s attach-and-return — see the task report for why those
// two streaming routes differ). To test it without hanging the test suite,
// this drives one frame and one detection event through, then makes the
// writer's next `write` throw (simulating the client disconnecting) so the
// handler's internal task group observes the failure and returns instead of
// running forever.

@Test func eventsStreamsBothFrameAndDetectionEventsThenExitsOnWriteFailure() async throws {
    let f = try await Fixture.make()
    // Enabled behaviors must include nosePicking for the fixture hit below
    // to reach the sink — apply() with enabled:false never touches the
    // camera, so this stays off real AVFoundation.
    var c = VibeCheckConfig.default
    c.enabled = false
    await f.engine.apply(c)

    let handler = try #require(await f.router.route("/api/events"))
    let writer = RecordingWriter()

    let handlerTask = Task {
        try? await handler(request("GET", "/api/events"), writer)
    }

    // Give the handler a moment to attach its subscriptions, then push a
    // frame (always published) and a confirmed detection (dwell satisfied
    // across two ingests) through the SAME engine/sink the route captured.
    try await Task.sleep(for: .milliseconds(50))
    let hit = LandmarkFrame(
        hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
        face: FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                            nose: CGPoint(x: 0.5, y: 0.5),
                            mouth: CGPoint(x: 0.5, y: 0.62))
    )
    await f.engine.ingestForTesting(hit, at: 0)
    await f.engine.ingestForTesting(hit, at: 0.2)

    // Poll briefly for both event kinds to land, then force a write failure
    // so the handler's task group unwinds instead of streaming forever.
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        let body = await writer.body
        if body.contains(Data("event: frame".utf8)), body.contains(Data("event: detection".utf8)) {
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let body = String(decoding: await writer.body, as: UTF8.self)
    #expect(body.contains("event: frame\n"))
    #expect(body.contains("event: detection\n"))
    #expect(body.contains("\"behavior\":\"nosePicking\""))

    await writer.setFailNextWrite(true)
    // Any further frame publish will now hit the failing write and end the
    // handler. `ingestForTesting` also republishes a frame each call.
    await f.engine.ingestForTesting(hit, at: 10)

    // The handler task must complete (not hang) once its write fails.
    try await withTimeout(seconds: 3) {
        _ = await handlerTask.value
    }
}

/// Small helper: fails the test rather than hanging forever if `body` does
/// not complete in time — used only to bound the one test above that awaits
/// a background handler task's completion.
private func withTimeout(seconds: Double, _ body: @escaping @Sendable () async -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError.timedOut
        }
        try await group.next()
        group.cancelAll()
    }
}

private enum TimeoutError: Error { case timedOut }
