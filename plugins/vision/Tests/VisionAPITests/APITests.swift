import Testing
import Foundation
import VCPluginSDK
@testable import VisionAPI

// Exercises the route table `registerVisionRoutes` installs on a real
// `VCRouter`, entirely in-process — no HTTP socket, no camera, no live
// kernel. That is a deliberate, honest boundary: these prove the HANDLERS
// (status codes, the JSON shape `/api/*` promises, the error discipline where
// a caller's mistake carries its message and ours does not), driven by
// fixtures that stand in for the capture side. What they do NOT prove is that
// NIO's framing or core's proxy deliver the same bytes end to end — that is a
// Go e2e's job, against the built binary.
//
// Nothing here touches AVFoundation, by construction rather than by luck:
// `VisionAPI` cannot reach a camera at all. Every fact it serves arrives
// through the four protocols in `VisionSurface.swift`, which is exactly why
// they live in this target.

// MARK: - Fixtures

private actor RecordingWriter: VCResponseWriter {
    private(set) var status: Int?
    private(set) var headers: [String: String] = [:]
    private(set) var body = Data()
    private(set) var finished = false
    private var failNextWrite = false

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

private actor FakeState: VisionStateSource {
    private var state: VisionState
    init(_ state: VisionState) { self.state = state }
    func visionState() async -> VisionState { state }
    func set(_ state: VisionState) { self.state = state }
}

private actor FakeCamera: VisionCameraControl {
    private var devices: [VisionCameraDevice]
    private var outcome: VisionCameraSelectionOutcome
    private(set) var selectionAttempts: [String] = []

    init(devices: [VisionCameraDevice] = [], outcome: VisionCameraSelectionOutcome = .selected) {
        self.devices = devices
        self.outcome = outcome
    }

    func availableCameras() async -> [VisionCameraDevice] { devices }

    func selectCamera(id: String) async -> VisionCameraSelectionOutcome {
        selectionAttempts.append(id)
        return outcome
    }

    func setOutcome(_ outcome: VisionCameraSelectionOutcome) { self.outcome = outcome }
}

private actor FakePreview: VisionPreviewSink {
    private(set) var attachedCount = 0
    func attach(_ writer: any VCResponseWriter) async {
        attachedCount += 1
        // A real sink sends the multipart head here; mimicking it keeps the
        // route's contract ("the sink owns the response from now on")
        // observable in the recorded writer.
        try? await writer.writeHead(status: 200, headers: [
            "Content-Type": "multipart/x-mixed-replace; boundary=vcframe",
        ])
    }
}

private actor FakeOverlay: VisionOverlaySource {
    private var continuations: [UUID: AsyncStream<VisionOverlayFrame>.Continuation] = [:]

    func overlayFrames() async -> AsyncStream<VisionOverlayFrame> {
        let (stream, continuation) = AsyncStream<VisionOverlayFrame>.makeStream(
            of: VisionOverlayFrame.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        let key = UUID()
        continuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.drop(key) }
        }
        return stream
    }

    func emit(_ frame: VisionOverlayFrame) {
        for continuation in continuations.values { continuation.yield(frame) }
    }

    var subscriberCount: Int { continuations.count }

    private func drop(_ key: UUID) { continuations.removeValue(forKey: key) }
}

private struct Fixture {
    let router = VCRouter()
    let state: FakeState
    let camera: FakeCamera
    let preview = FakePreview()
    let overlay = FakeOverlay()

    static func make(
        state: VisionState = .cameraOff,
        devices: [VisionCameraDevice] = [.builtIn, .external],
        outcome: VisionCameraSelectionOutcome = .selected,
        ui: Data? = Data("<!doctype html><title>Vision</title>".utf8)
    ) async -> Fixture {
        let f = Fixture(state: FakeState(state), camera: FakeCamera(devices: devices, outcome: outcome))
        await registerVisionRoutes(
            router: f.router,
            state: f.state,
            camera: f.camera,
            preview: f.preview,
            overlay: f.overlay,
            loadUI: { path in path == "ui/index.html" ? ui : nil }
        )
        return f
    }

    init(state: FakeState, camera: FakeCamera) {
        self.state = state
        self.camera = camera
    }
}

private extension VisionCameraDevice {
    static let builtIn = VisionCameraDevice(id: "built-in-id", name: "FaceTime HD Camera")
    static let external = VisionCameraDevice(id: "external-id", name: "Studio Display Camera")
}

private extension VisionState {
    /// Nothing running, nobody asking — a fresh install.
    static let cameraOff = VisionState(
        camera: VisionCameraState(
            selectedDeviceID: VisionCameraDevice.builtIn.id,
            selectedDeviceName: VisionCameraDevice.builtIn.name,
            isOpen: false,
            permission: .authorized
        ),
        topics: VisionTopicCatalog.ordered.map { VisionTopicStatus(topic: $0, isRunning: false) }
    )

    /// The §7 example: face for two plugins, body pose for postures.
    static func running(now: Date = Date()) -> VisionState {
        VisionState(
            camera: VisionCameraState(
                selectedDeviceID: VisionCameraDevice.builtIn.id,
                selectedDeviceName: VisionCameraDevice.builtIn.name,
                isOpen: true,
                permission: .authorized,
                frameWidth: 1280,
                frameHeight: 720,
                isMirrored: true
            ),
            topics: [
                VisionTopicStatus(topic: VisionTopicCatalog.face, isRunning: true, fps: 30,
                                  subscribers: 2, requesters: ["vibecheck", "blink-jump"]),
                VisionTopicStatus(topic: VisionTopicCatalog.hands, isRunning: false),
                VisionTopicStatus(topic: VisionTopicCatalog.bodyPose, isRunning: true, fps: 2,
                                  subscribers: 1, requesters: ["postures"]),
                VisionTopicStatus(topic: VisionTopicCatalog.segmentation, isRunning: false),
                VisionTopicStatus(topic: VisionTopicCatalog.signals, isRunning: true, fps: 30,
                                  subscribers: 1, requesters: ["blink-jump"]),
            ],
            requests: [
                VisionActiveRequest(requester: "postures",
                                    topics: [VisionTopicCatalog.bodyPose],
                                    fps: 2,
                                    expiresAt: now.addingTimeInterval(22)),
            ]
        )
    }
}

private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data = Data()) -> VCRequest {
    VCRequest(method: method, path: path, query: query, body: body)
}

/// Decodes a recorded body as a raw JSON object, so assertions bind to the
/// KEY NAMES on the wire rather than to `VisionStateDTO`'s Swift properties.
/// Round-tripping through the DTO would agree with itself by construction and
/// would not notice a rename that breaks every existing client.
private func jsonObject(_ writer: RecordingWriter) async throws -> [String: Any] {
    let data = await writer.body
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private func call(
    _ f: Fixture, _ method: String, _ path: String, body: Data = Data()
) async throws -> RecordingWriter {
    let handler = try #require(await f.router.route(path))
    let writer = RecordingWriter()
    try await handler(request(method, path, body: body), writer)
    return writer
}

// MARK: - /health belongs to the SDK

// `VCHost.connect` installs `/health` BEFORE it binds, because core's prober
// starts the instant the plugin registers. Registering one here would replace
// the SDK's handler with one that does not know core force-clears `detail` on
// any transition to `up` — so `{"status":"ok","detail":"…"}` would silently
// discard its text. This is a one-line guard against a whole class of that.
@Test func visionRoutesDoNotShadowTheSDKHealthRoute() async throws {
    let f = await Fixture.make()
    #expect(await f.router.route("/health") == nil)
}

// MARK: - GET /api/state

@Test func stateNamesTheRunningModelsTheirRateAndWhoAskedForEach() async throws {
    let f = await Fixture.make(state: .running())
    let writer = try await call(f, "GET", "/api/state")

    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "application/json")
    let json = try await jsonObject(writer)

    let running = try #require(json["running"] as? [[String: Any]])
    // Pipeline order, not whatever order the capture side happened to
    // enumerate: face, then body pose, then signals.
    #expect(running.map { $0["topic"] as? String } == [
        VisionTopicCatalog.face, VisionTopicCatalog.bodyPose, VisionTopicCatalog.signals,
    ])

    let face = running[0]
    #expect(face["model"] as? String == "face")
    #expect(face["fps"] as? Int == 30)
    #expect(face["subscribers"] as? Int == 2)
    // Sorted, so the readout does not reshuffle between polls.
    #expect(face["requesters"] as? [String] == ["blink-jump", "vibecheck"])

    let body = try #require(running[1] as [String: Any])
    #expect(body["model"] as? String == "body pose")
    #expect(body["requesters"] as? [String] == ["postures"])
}

// "hands is NOT running" is itself a privacy claim. A readout that only
// listed running models could not distinguish "not running" from "not
// implemented", so the idle list is part of the contract, not padding.
@Test func stateAlsoListsTheModelsThatAreNotRunning() async throws {
    let f = await Fixture.make(state: .running())
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))

    let idle = try #require(json["idle"] as? [[String: Any]])
    #expect(idle.map { $0["topic"] as? String } == [
        VisionTopicCatalog.hands, VisionTopicCatalog.segmentation,
    ])
    #expect(idle[0]["fps"] as? Int == 0)
}

@Test func stateReportsTheSelectedCameraAndEveryAvailableDevice() async throws {
    let f = await Fixture.make(state: .running())
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))

    let camera = try #require(json["camera"] as? [String: Any])
    #expect(camera["open"] as? Bool == true)
    #expect(camera["permission"] as? String == "authorized")
    #expect(camera["deviceId"] as? String == VisionCameraDevice.builtIn.id)
    #expect(camera["deviceName"] as? String == "FaceTime HD Camera")
    // The overlay's aspect-fill mapping has no other source for these.
    #expect(camera["frameWidth"] as? Int == 1280)
    #expect(camera["frameHeight"] as? Int == 720)
    #expect(camera["mirrored"] as? Bool == true)

    let devices = try #require(json["devices"] as? [[String: Any]])
    #expect(devices.count == 2)
    #expect(devices[0]["selected"] as? Bool == true)
    #expect(devices[1]["selected"] as? Bool == false)
}

@Test func stateReportsLiveRequestsWithAnEpochExpiryAndACountdown() async throws {
    let now = Date()
    let f = await Fixture.make(state: .running(now: now))
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))

    let requests = try #require(json["requests"] as? [[String: Any]])
    #expect(requests.count == 1)
    #expect(requests[0]["requester"] as? String == "postures")
    #expect(requests[0]["fps"] as? Int == 2)
    #expect(requests[0]["topics"] as? [String] == [VisionTopicCatalog.bodyPose])
    // Unix epoch seconds, not JSONEncoder's default reference date — a
    // non-Apple client reading the default would see a 2001-relative
    // timestamp and place the expiry 31 years in the past.
    let expiresAt = try #require(requests[0]["expiresAt"] as? Double)
    #expect(abs(expiresAt - now.addingTimeInterval(22).timeIntervalSince1970) < 1)
    let remaining = try #require(requests[0]["expiresInSeconds"] as? Int)
    #expect(remaining >= 21 && remaining <= 22)
}

@Test func stateRejectsAnythingButGET() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "POST", "/api/state")
    #expect(await writer.status == 405)
    #expect(await writer.headers["Allow"] == "GET")
}

// MARK: - The `subscriber with no request` warning (§5.3)

// Demand governs whether vision MAY run a model; the request union governs
// whether it DOES. A consumer that subscribes and never publishes a request
// receives nothing at all, which is indistinguishable from a broken bus —
// so this warning is not "just logging", it is the only thing in the system
// that can tell that consumer's author what they forgot.
@Test func stateWarnsWhenATopicHasSubscribersButNobodyRequestedIt() async throws {
    let state = VisionState(
        camera: VisionCameraState(permission: .authorized),
        topics: [
            VisionTopicStatus(topic: VisionTopicCatalog.hands, isRunning: false,
                              subscribers: 1, requesters: []),
        ]
    )
    let f = await Fixture.make(state: state)
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))

    let warnings = try #require(json["warnings"] as? [[String: Any]])
    #expect(warnings.count == 1)
    #expect(warnings[0]["code"] as? String == "subscriberWithNoRequest")
    #expect(warnings[0]["topic"] as? String == VisionTopicCatalog.hands)
    #expect(warnings[0]["subscribers"] as? Int == 1)
    let message = try #require(warnings[0]["message"] as? String)
    #expect(message.contains("vision.request.v1"))
}

@Test func aTopicWithBothSubscribersAndARequesterIsNotAWarning() async throws {
    let f = await Fixture.make(state: .running())
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))
    #expect((json["warnings"] as? [[String: Any]])?.isEmpty == true)
}

// The false positive that would have made the warning worthless: on a fresh
// install every topic is idle with nobody subscribed, and warning about that
// would bury the real signal under permanent noise.
@Test func aTopicNobodyIsSubscribedToIsNotAWarning() async throws {
    let warnings = VisionWarning.derive(from: VisionTopicCatalog.ordered.map {
        VisionTopicStatus(topic: $0, isRunning: false, subscribers: 0, requesters: [])
    })
    #expect(warnings.isEmpty)
}

// Pins the stderr line to the exact shape the design specifies, because the
// capture side is supposed to log THIS string (rather than invent a second
// wording) whenever the condition transitions.
@Test func theWarningsLogLineMatchesTheSpecifiedFormat() {
    let warning = VisionWarning(code: .subscriberWithNoRequest, topic: "vision.face.v1", subscribers: 3)
    #expect(warning.logLine == "subscriber with no request topic=vision.face.v1 subscribers=3")
}

// MARK: - The privacy sentence

@Test func summarySaysWhoTurnedTheCameraOn() async throws {
    let f = await Fixture.make(state: .running())
    let json = try await jsonObject(try await call(f, "GET", "/api/state"))
    let summary = try #require(json["summary"] as? String)

    // The sentence §7 asks for, verbatim in structure: "the camera is on
    // because postures wants body pose".
    #expect(summary.hasPrefix("The camera is on because "))
    #expect(summary.contains("postures wants body pose"))
    #expect(summary.contains("blink-jump and vibecheck want face"))
}

@Test func summaryForAClosedCameraSaysSoWithoutBlamingAnybody() {
    let line = VisionSummary.line(
        camera: VisionCameraState(permission: .authorized),
        topics: VisionTopicCatalog.ordered.map { VisionTopicStatus(topic: $0, isRunning: false) }
    )
    #expect(line == "The camera is off. No models are running and no plugin has asked for one.")
}

@Test func summaryNamesDeniedAccessRatherThanPretendingNobodyAsked() {
    let line = VisionSummary.line(
        camera: VisionCameraState(permission: .denied),
        topics: [VisionTopicStatus(topic: VisionTopicCatalog.face, isRunning: false,
                                   subscribers: 1, requesters: ["vibecheck"])]
    )
    #expect(line.contains("denied"))
}

// An open session with nothing running is the failure the privacy readout
// exists to catch, so it must never render as a comfortable blank.
@Test func summaryDoesNotStaySilentAboutAnOpenCameraWithNoModels() {
    let line = VisionSummary.line(
        camera: VisionCameraState(isOpen: true, permission: .authorized),
        topics: [VisionTopicStatus(topic: VisionTopicCatalog.face, isRunning: false)]
    )
    #expect(line == "The camera is on but no models are running.")
}

@Test func topicDisplayNamesCoverUnknownTopicsWithoutDroppingThem() {
    #expect(VisionTopicCatalog.displayName(for: VisionTopicCatalog.bodyPose) == "body pose")
    // A provider that grows a sixth topic shows up in the readout the day it
    // ships, not the day this table is updated.
    #expect(VisionTopicCatalog.displayName(for: "vision.gaze_target.v1") == "gaze target")
}

// MARK: - GET /api/devices, PUT /api/device

@Test func devicesListsEveryCameraAndMarksTheSelectedOne() async throws {
    let f = await Fixture.make(state: .running())
    let writer = try await call(f, "GET", "/api/devices")
    #expect(await writer.status == 200)

    let json = try await jsonObject(writer)
    let devices = try #require(json["devices"] as? [[String: Any]])
    #expect(devices.map { $0["name"] as? String } == ["FaceTime HD Camera", "Studio Display Camera"])
    #expect(devices[0]["selected"] as? Bool == true)
}

@Test func devicesRejectsAnythingButGET() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "PUT", "/api/devices")
    #expect(await writer.status == 405)
}

@Test func selectingADeviceForwardsTheIdAndAnswersWithTheDeviceList() async throws {
    let f = await Fixture.make(state: .running())
    let writer = try await call(f, "PUT", "/api/device",
                                body: Data(#"{"deviceId":"external-id"}"#.utf8))

    #expect(await writer.status == 200)
    #expect(await f.camera.selectionAttempts == ["external-id"])
    let json = try await jsonObject(writer)
    #expect((json["devices"] as? [[String: Any]])?.count == 2)
}

@Test func selectingWithMalformedJSONIs400() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "PUT", "/api/device", body: Data("{not json".utf8))
    #expect(await writer.status == 400)
    #expect(await f.camera.selectionAttempts.isEmpty)
}

@Test func selectingWithAnEmptyDeviceIdIs400() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "PUT", "/api/device", body: Data(#"{"deviceId":""}"#.utf8))
    #expect(await writer.status == 400)
    #expect(await f.camera.selectionAttempts.isEmpty)
}

@Test func selectingAnUnattachedDeviceIs404WithAMessage() async throws {
    let f = await Fixture.make(outcome: .unknownDevice)
    let writer = try await call(f, "PUT", "/api/device", body: Data(#"{"deviceId":"gone"}"#.utf8))
    #expect(await writer.status == 404)
    let json = try await jsonObject(writer)
    #expect(json["error"] as? String == "no camera with that id is attached")
}

// The error-discipline half that actually matters: a capture failure's text
// can name a device path, which is not the client's to see. It gets logged
// server-side and answered generically.
@Test func aCaptureFailureIs500AndNeverLeaksItsDetail() async throws {
    let f = await Fixture.make(outcome: .failed("/dev/video0: -[AVCaptureDevice lockForConfiguration] failed"))
    let writer = try await call(f, "PUT", "/api/device", body: Data(#"{"deviceId":"built-in-id"}"#.utf8))

    #expect(await writer.status == 500)
    let bodyText = String(decoding: await writer.body, as: UTF8.self)
    #expect(bodyText.contains("internal error"))
    #expect(bodyText.contains("lockForConfiguration") == false)
    #expect(bodyText.contains("/dev/") == false)
}

@Test func deviceSelectionRejectsAnythingButPUT() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "GET", "/api/device")
    #expect(await writer.status == 405)
    #expect(await writer.headers["Allow"] == "PUT")
}

// MARK: - GET /

@Test func rootServesTheBundledHTMLUncached() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "GET", "/")

    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "text/html; charset=utf-8")
    // A webview caching this page would survive a plugin rebuild and serve
    // last week's UI against today's JSON.
    #expect(await writer.headers["Cache-Control"] == "no-store")
    #expect(await writer.finished)
}

// A missing resource must be a 500 an operator can read — never a
// `fatalError`. `supervisor.go` charges an unrequested exit as a failed
// start, and five park the plugin in StateFailed until a manual restart.
@Test func rootAnswers500RatherThanCrashingWhenTheUIResourceIsMissing() async throws {
    let f = await Fixture.make(ui: nil)
    let writer = try await call(f, "GET", "/")
    #expect(await writer.status == 500)
    #expect(await writer.finished)
}

@Test func rootRejectsAnythingButGET() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "POST", "/")
    #expect(await writer.status == 405)
}

// MARK: - GET /preview.mjpeg

@Test func previewAttachesTheWriterToTheSinkAndReturns() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "GET", "/preview.mjpeg")

    // Attach-and-return: the handler completes immediately, and the sink —
    // not this request's Task — owns the writer from here on. That is what
    // lets several viewers share one camera, and what makes the attached
    // count the thing capture checks before encoding a JPEG.
    #expect(await f.preview.attachedCount == 1)
    #expect(await writer.status == 200)
    #expect(await writer.headers["Content-Type"] == "multipart/x-mixed-replace; boundary=vcframe")
    #expect(await writer.finished == false)
}

@Test func previewRejectsAnythingButGET() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "POST", "/preview.mjpeg")
    #expect(await writer.status == 405)
    #expect(await f.preview.attachedCount == 0)
}

// MARK: - GET /api/events

@Test func eventsStreamsOverlayFramesAndStopsWhenTheClientGoesAway() async throws {
    let f = await Fixture.make(state: .running())
    let handler = try #require(await f.router.route("/api/events"))
    let writer = RecordingWriter()

    let handlerTask = Task { try? await handler(request("GET", "/api/events"), writer) }

    // Wait for the handler to subscribe rather than sleeping a fixed amount
    // and hoping: a frame emitted before `overlayFrames()` was called would
    // be dropped and this test would flake.
    try await waitUntil { await f.overlay.subscriberCount == 1 }
    await f.overlay.emit(sampleFrame())

    try await waitUntil {
        String(decoding: await writer.body, as: UTF8.self).contains("event: frame")
    }
    #expect(await writer.headers["Content-Type"] == "text/event-stream")

    let frame = try await decodeFirstSSEFrame(writer)
    #expect(frame["seq"] as? Int == 7)
    #expect(frame["imageWidth"] as? Int == 1280)
    let face = try #require(frame["face"] as? [String: Any])
    let points = try #require(face["points"] as? [[String: Any]])
    #expect(points.count == 2)
    // Viewer space, straight through: no flip of either axis happens on this
    // path, because the provider already mirrored (§4.3).
    #expect(points[0]["x"] as? Double == 0.25)
    #expect(points[0]["y"] as? Double == 0.5)
    let hands = try #require(frame["hands"] as? [[String: Any]])
    #expect(hands[0]["chirality"] as? String == "right")
    let body = try #require(frame["body"] as? [[String: Any]])
    #expect(body[0]["name"] as? String == "left_shoulder")

    // A closed tab is only ever observed as a failing write; the handler must
    // end rather than stream into a dead socket forever.
    await writer.setFailNextWrite(true)
    await f.overlay.emit(sampleFrame())
    try await withTimeout(seconds: 3) { _ = await handlerTask.value }
    // And the provider must learn about it, or it would keep building
    // overlay frames for a viewer that is gone.
    try await waitUntil { await f.overlay.subscriberCount == 0 }
}

// Pins the segmentation mask's wire encoding. The expected base64 was
// computed independently — `python3 -c "import base64;
// print(base64.b64encode(bytes([0xE0, 0x01])))"` -> b'4AE=' — rather than by
// re-deriving `MaskDTO`'s own formula, so a change of bit order or byte
// layout on either side fails here instead of quietly agreeing with itself.
// The browser's decoder (`0x80 >> (i & 7)`, row-major) has to match this and
// the proto's `bytes mask`, all three, which is why this is pinned at all.
@Test func eventsCarryTheSegmentationMaskAsBase64OfTheProtoPacking() async throws {
    let f = await Fixture.make(state: .running())
    let handler = try #require(await f.router.route("/api/events"))
    let writer = RecordingWriter()
    let handlerTask = Task { try? await handler(request("GET", "/api/events"), writer) }

    try await waitUntil { await f.overlay.subscriberCount == 1 }
    var frame = sampleFrame()
    frame.segmentation = VisionOverlayFrame.Mask(cols: 4, rows: 4, packed: [0xE0, 0x01])
    await f.overlay.emit(frame)

    try await waitUntil {
        String(decoding: await writer.body, as: UTF8.self).contains("segmentation")
    }
    let decoded = try await decodeFirstSSEFrame(writer)
    let mask = try #require(decoded["segmentation"] as? [String: Any])
    #expect(mask["cols"] as? Int == 4)
    #expect(mask["rows"] as? Int == 4)
    #expect(mask["bits"] as? String == "4AE=")

    await writer.setFailNextWrite(true)
    await f.overlay.emit(frame)
    try await withTimeout(seconds: 3) { _ = await handlerTask.value }
}

@Test func eventsRejectAnythingButGET() async throws {
    let f = await Fixture.make()
    let writer = try await call(f, "POST", "/api/events")
    #expect(await writer.status == 405)
    #expect(await f.overlay.subscriberCount == 0)
}

// MARK: - Helpers

private func sampleFrame() -> VisionOverlayFrame {
    VisionOverlayFrame(
        seq: 7,
        ts: Date(timeIntervalSince1970: 1_700_000_000),
        imageWidth: 1280,
        imageHeight: 720,
        face: VisionOverlayFrame.Face(
            bounds: VisionOverlayFrame.Rect(x: 0.2, y: 0.1, width: 0.3, height: 0.4),
            points: [
                VisionOverlayFrame.Point(x: 0.25, y: 0.5),
                VisionOverlayFrame.Point(x: 0.35, y: 0.55),
            ],
            confidence: 0.9
        ),
        hands: [
            VisionOverlayFrame.Hand(
                chirality: "right",
                points: [VisionOverlayFrame.Point(x: 0.6, y: 0.7)],
                confidence: 0.8
            ),
        ],
        body: [
            VisionOverlayFrame.Joint(
                name: "left_shoulder",
                point: VisionOverlayFrame.Point(x: 0.4, y: 0.8),
                confidence: 0.75
            ),
        ]
    )
}

/// Parses the first `data:` payload out of an SSE body.
private func decodeFirstSSEFrame(_ writer: RecordingWriter) async throws -> [String: Any] {
    let text = String(decoding: await writer.body, as: UTF8.self)
    let line = try #require(
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("data: ") }),
        "no SSE data line in \(text)"
    )
    let json = String(line.dropFirst("data: ".count))
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try #require(object as? [String: Any])
}

/// Polls `condition` to a deadline. Fails the test instead of hanging
/// `swift test` forever, which is the whole reason this exists rather than a
/// bare `await` on something that may never happen.
private func waitUntil(
    seconds: Double = 3,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition never became true within \(seconds)s")
}

private func withTimeout<T: Sendable>(
    seconds: Double = 3, _ body: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError.timedOut
        }
        guard let result = try await group.next() else { throw TimeoutError.timedOut }
        group.cancelAll()
        return result
    }
}

private enum TimeoutError: Error { case timedOut }
