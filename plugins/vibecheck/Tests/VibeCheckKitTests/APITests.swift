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
    let snooze: SnoozeGate
    let sink: HostSink
    let engine: DetectionEngine

    /// ONE `SnoozeGate` instance, shared by `sink` (which checks it in
    /// `fired`) and the registered `/api/snooze` route (which sets it) —
    /// exactly like `main.swift`'s composition root passes a single
    /// `snoozeGate` to both `HostSink(...)` and `registerVibeCheckRoutes`.
    /// An earlier version of this fixture built a SEPARATE, unused
    /// `SnoozeGate()` for `sink` while wiring a different one to the
    /// routes — the fixture still worked (both gates started fresh and
    /// unsnoozed), but it meant nothing here could ever have caught a
    /// `main.swift` regression that passed the wrong gate to one side,
    /// because `snoozeRouteSuppressesTheNextAlertButNotTheDetectionBroadcast`
    /// below is the only test that exercises the gate at all, and it would
    /// have silently tested two independent, always-unsnoozed gates
    /// instead of one shared, genuinely-snoozed one.
    static func make() async throws -> Fixture {
        let dir = try tempDir()
        let config = try ConfigStore(directory: dir)
        let prefs = try AlertPrefsStore(directory: dir)
        let counts = try CountsStore(directory: dir)
        let snooze = SnoozeGate()
        let sink = HostSink(prefs: prefs, snooze: snooze)
        let engine = DetectionEngine(config: config, counts: counts, prefs: prefs, sink: sink)
        let f = Fixture(config: config, prefs: prefs, counts: counts, snooze: snooze, sink: sink, engine: engine)
        await registerVibeCheckRoutes(
            router: f.router, engine: f.engine, config: f.config, prefs: f.prefs,
            preview: f.preview, sink: f.sink, snooze: f.snooze,
            loadIcon: { id in id == "nail-biting" ? Data("<svg/>".utf8) : nil }
        )
        return f
    }

    init(config: ConfigStore, prefs: AlertPrefsStore, counts: CountsStore, snooze: SnoozeGate,
         sink: HostSink, engine: DetectionEngine) {
        self.config = config
        self.prefs = prefs
        self.counts = counts
        self.snooze = snooze
        self.sink = sink
        self.engine = engine
    }
}

private actor SpyAlertHost: AlertHost {
    private(set) var alerts: [VCAlert] = []
    func alert(_ a: VCAlert) async throws { alerts.append(a) }
    func publish(topic: String, payload: Data) async throws {}
}

private func nosePickingHit() -> LandmarkFrame {
    LandmarkFrame(
        hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
        face: FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                            nose: CGPoint(x: 0.5, y: 0.5),
                            mouth: CGPoint(x: 0.5, y: 0.62))
    )
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
    // the same clamped values, not just what's on disk. `apply` now runs in
    // a DETACHED Task (fixed after review: an inline `await engine.apply`
    // here would block the HTTP response on a TCC prompt whenever
    // `enabled` transitions to `true` — see API.swift's comment), so this
    // polls for a bounded window instead of asserting immediately after the
    // handler returns, which raced the detached Task's scheduling.
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await f.engine.snapshot().config.sensitivity == 1.0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
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

// The behavior snooze exists for: hitting the route must actually suppress
// the next alert, not merely flip a gate nothing downstream reads. This is
// the test the fixture's earlier two-`SnoozeGate` bug (review finding #3)
// would have sailed straight through — `Fixture.make()` now wires exactly
// one `SnoozeGate` to both `sink` and the routes (see its doc comment), and
// this is what actually exercises that being true rather than merely
// asserting it in a comment.
@Test func snoozeRouteSuppressesTheNextAlertButNotTheDetectionBroadcast() async throws {
    let f = try await Fixture.make()
    let spyHost = SpyAlertHost()
    await f.sink.attach(host: spyHost)

    let stream = await f.sink.events()

    let snoozeHandler = try #require(await f.router.route("/api/snooze"))
    try await snoozeHandler(request("POST", "/api/snooze", query: ["minutes": "10"]), RecordingWriter())
    #expect(await f.snooze.isActive() == true)

    let hit = nosePickingHit()
    await f.engine.ingestForTesting(hit, at: 0)
    await f.engine.ingestForTesting(hit, at: 0.2)   // dwell (0.15) satisfied -> fires

    // Still broadcast to SSE: snoozing suppresses the popup, not the fact
    // that a detection happened. Bounded (not a bare `await iterator.next()`
    // — that shape was review finding B, a same-round regression of the
    // hang-instead-of-fail anti-pattern finding 5 had just removed from
    // HostSinkTests.swift): a snooze or fan-out regression here now fails
    // fast instead of hanging `swift test` forever.
    let received = try await withTimeout { await firstDetectionEvent(from: stream) }
    #expect(received?.behavior == .nosePicking)

    // But the alert itself never reached the host — this is the one
    // assertion that actually proves the route and the sink share a gate.
    #expect(await spyHost.alerts.isEmpty)
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

/// Reads the first element off a `HostSink.events()` stream, for use inside
/// `withTimeout` below — takes the STREAM (not a mutating `Iterator`)
/// specifically so the read can run inside a `@Sendable` `Task` closure
/// without capturing a mutable local var across the concurrency boundary.
/// Same shape as `HostSinkTests.swift`'s own `firstEvent(from:)` —
/// duplicated rather than shared because Swift's file-private access means
/// the two test targets' files can't see each other's `private` helpers.
private func firstDetectionEvent(from stream: AsyncStream<DetectionBroadcast>) async -> DetectionBroadcast? {
    for await value in stream { return value }
    return nil
}

/// Fails the test rather than hanging forever if `body` does not complete in
/// time. Generic so it covers both this file's uses: waiting on a
/// background handler `Task`'s completion (`T == Void`) and reading one
/// element off an `AsyncStream` (`T == DetectionBroadcast?`).
private func withTimeout<T: Sendable>(
    seconds: Double = 3, _ body: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError.timedOut
        }
        guard let result = try await group.next() else {
            throw TimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}

private enum TimeoutError: Error { case timedOut }
