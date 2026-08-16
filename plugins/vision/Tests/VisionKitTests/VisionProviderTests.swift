import Foundation
import Testing
import VCKStubs
import VCPluginSDK
@testable import VisionKit

/// A `VisionCameraControlling` that records instead of opening hardware.
///
/// `swift test` runs in a process with no `NSCameraUsageDescription` and no TCC
/// grant, so a test that reached a real `AVCaptureDevice.requestAccess` would
/// hang on a prompt or fail for reasons unrelated to the code under test. The
/// demand floor — "every vision topic at zero subscribers STOPS the session" —
/// is one of the most important behaviours here, and it is assertable only
/// because the thing being stopped can be this.
final class FakeCamera: VisionCameraControlling, @unchecked Sendable {
    let frameQueue = DispatchQueue(label: "test.fake.camera")

    private let lock = NSLock()
    private var startsLocked = 0
    private var stopsLocked = 0
    private var runningLocked = false
    private var frameRatesLocked: [Int] = []
    private var preferredLocked: String??
    private var resultLocked: CameraStartResult = .started
    private var devicesLocked: [VisionCamera] = [
        VisionCamera(id: "builtin", name: "MacBook Pro Camera", isDefault: true),
        VisionCamera(id: "external", name: "Studio Display Camera", isDefault: false),
    ]

    var starts: Int { lock.withLock { startsLocked } }
    var stops: Int { lock.withLock { stopsLocked } }
    var isRunning: Bool { lock.withLock { runningLocked } }
    var frameRates: [Int] { lock.withLock { frameRatesLocked } }
    var preferred: String?? { lock.withLock { preferredLocked } }

    func setResult(_ result: CameraStartResult) { lock.withLock { resultLocked = result } }

    var currentCamera: VisionCamera? {
        lock.withLock { runningLocked ? devicesLocked.first : nil }
    }

    func attach(_ receiver: any CameraFrameReceiver) {}
    func availableCameras() -> [VisionCamera] { lock.withLock { devicesLocked } }
    func setPreferredDevice(id: String?) { lock.withLock { preferredLocked = .some(id) } }

    func start() async -> CameraStartResult {
        lock.withLock {
            startsLocked += 1
            if resultLocked == .started { runningLocked = true }
            return resultLocked
        }
    }

    func stop() {
        lock.withLock {
            stopsLocked += 1
            runningLocked = false
        }
    }

    func reset() async { stop() }

    func setFrameRate(_ fps: Int) { lock.withLock { frameRatesLocked.append(fps) } }
}

/// The control plane end to end: demand + requests in, camera lifecycle and
/// the privacy readout out.
@Suite struct VisionProviderTests {
    private func makeProvider(camera: FakeCamera,
                              analyzer: FakeAnalyzer = FakeAnalyzer(),
                              publisher: SpyPublisher = SpyPublisher()) -> VisionProvider {
        VisionProvider(publisher: publisher, analyzer: analyzer, camera: camera)
    }

    private func demandEvent(_ topic: VisionTopic, _ subscribers: Int) -> VCEvent {
        let payload = Data(#"{"topic":"\#(topic.name)","subscribers":\#(subscribers)}"#.utf8)
        return VCEvent(topic: VCTopicDemand, payload: payload, ts: Date())
    }

    private func requestEvent(_ request: VCTRequest) throws -> VCEvent {
        VCEvent(topic: VisionRequestTopic, payload: try request.serializedData(), ts: Date())
    }

    @Test func demandAloneNeverOpensTheCamera() async {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))

        // Demand governs whether a model MAY run; the request union governs
        // whether it does. Opening the camera here would also mean a TCC
        // prompt fired for a consumer that never asked for anything.
        #expect(camera.starts == 0)
        #expect(camera.isRunning == false)
    }

    @Test func aRequestAloneNeverOpensTheCamera() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(try requestEvent(testRequest("vibecheck", [.face])))

        #expect(camera.starts == 0)
    }

    @Test func demandPlusARequestOpensTheCameraAtTheRequestedRate() async throws {
        let camera = FakeCamera()
        let analyzer = FakeAnalyzer()
        let provider = makeProvider(camera: camera, analyzer: analyzer)

        await provider.handle(demandEvent(.bodyPose, 1))
        await provider.handle(try requestEvent(testRequest("postures", [.bodyPose], fps: 2)))

        #expect(camera.starts == 1)
        #expect(camera.isRunning)
        #expect(camera.frameRates.last == 2)

        let snapshot = await provider.snapshot()
        #expect(snapshot.capturing)
        #expect(snapshot.captureFPS == 2)
        #expect(snapshot.permission == .granted)
        #expect(snapshot.running.map(\.topic) == ["vision.body_pose.v1"])
        #expect(snapshot.running[0].requesters == ["postures"])
        #expect(snapshot.activeModels == ["VNDetectHumanBodyPoseRequest"])
        // Every topic appears, running or not.
        #expect(snapshot.topics.count == VisionTopic.allCases.count)
    }

    @Test func demandDroppingToZeroStopsTheSessionDespiteALiveRequest() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face], fps: 15, ttl: 300)))
        #expect(camera.isRunning)

        // The consumer died without retracting. Demand is the floor and it is
        // not negotiable: the LED goes off even though the request is still
        // live for another five minutes.
        await provider.handle(demandEvent(.face, 0))

        #expect(camera.isRunning == false)
        #expect(camera.stops >= 1)
        let snapshot = await provider.snapshot()
        #expect(snapshot.capturing == false)
        #expect(snapshot.captureFPS == 0)
        #expect(snapshot.running.isEmpty)
    }

    @Test func retractingEveryRequestStopsTheSessionDespiteLiveDemand() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.hands, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.hands])))
        #expect(camera.isRunning)

        // "user disables vibecheck -> it publishes {topics: []}": its process
        // stays up and stays subscribed, so demand never moves. This is the
        // exact case the kernel's refcount cannot see and the request topic
        // exists to cover.
        await provider.handle(try requestEvent(testRequest("vibecheck", [])))

        #expect(camera.isRunning == false)
        let snapshot = await provider.snapshot()
        #expect(snapshot.capturing == false)
        // Still a live requester, just wanting nothing.
        #expect(snapshot.requesters.map(\.requester) == ["vibecheck"])
        #expect(snapshot.requesters[0].topics.isEmpty)
        // …and now the subscriber it left behind is receiving nothing, which
        // is precisely what the warning is for.
        #expect(snapshot.warnings.map(\.topic) == ["vision.hands.v1"])
    }

    @Test func aSubscriberWithNoRequestIsSurfacedNotJustLogged() async {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 3))

        let snapshot = await provider.snapshot()
        #expect(snapshot.warnings == [VisionWarning(topic: "vision.face.v1", subscribers: 3)])
        #expect(snapshot.warnings[0].message
                == "subscriber with no request topic=vision.face.v1 subscribers=3")
        // The topic row says the same thing in structured form: subscribed,
        // nobody asked, not running.
        let face = snapshot.topics.first { $0.topic == "vision.face.v1" }
        #expect(face?.subscribers == 3)
        #expect(face?.requesters.isEmpty == true)
        #expect(face?.running == false)
    }

    @Test func theWarningClearsWhenTheMissingRequestArrives() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        #expect(await provider.snapshot().warnings.isEmpty == false)

        await provider.handle(try requestEvent(testRequest("vibecheck", [.face])))
        #expect(await provider.snapshot().warnings.isEmpty)
    }

    @Test func aDeniedCameraDegradesAndIsRetriedRatherThanExiting() async throws {
        let camera = FakeCamera()
        camera.setResult(.denied)
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face])))

        #expect(camera.starts == 1)
        #expect(camera.isRunning == false)
        let snapshot = await provider.snapshot()
        #expect(snapshot.permission == .denied)
        #expect(snapshot.capturing == false)

        // The retry is BACKED OFF, not abandoned and not hammered: another
        // reconcile a moment later must not re-prompt. Core charges any
        // unrequested exit as a failed start, so the only correct answer to a
        // denial is to keep asking — slowly.
        await provider.reconcile()
        #expect(camera.starts == 1)
    }

    @Test func aMissingCameraIsReportedDistinctlyFromADenial() async throws {
        let camera = FakeCamera()
        camera.setResult(.noDevice)
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face])))

        #expect(await provider.snapshot().permission == .noDevice)
    }

    @Test func anExpiredRequestClosesTheCameraOnTheNextReconcile() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        // A one-second TTL, so the sweep can be driven by a single explicit
        // reconcile rather than a 30-second sleep.
        await provider.handle(try requestEvent(testRequest("wedged", [.face], ttl: 1)))
        #expect(camera.isRunning)

        try await Task.sleep(for: .milliseconds(1100))
        await provider.reconcile()

        #expect(camera.isRunning == false)
        let snapshot = await provider.snapshot()
        #expect(snapshot.requesters.isEmpty)
        // Demand is still 1, so the topic is now a subscriber with no request.
        #expect(snapshot.warnings.map(\.topic) == ["vision.face.v1"])
    }

    @Test func perTopicRatesSurviveIntoTheReadoutIndependently() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        await provider.handle(demandEvent(.bodyPose, 1))
        await provider.handle(try requestEvent(testRequest("blink-jump", [.face], fps: 30)))
        await provider.handle(try requestEvent(testRequest("postures", [.bodyPose], fps: 2)))

        let snapshot = await provider.snapshot()
        let byTopic = Dictionary(uniqueKeysWithValues: snapshot.topics.map { ($0.topic, $0) })
        #expect(byTopic["vision.face.v1"]?.fps == 30)
        #expect(byTopic["vision.body_pose.v1"]?.fps == 2)
        // The session runs at max(requested), capped at 30.
        #expect(snapshot.captureFPS == 30)
    }

    @Test func aSecondRequesterForTheSameTopicRaisesTheRateWithoutAReleaseCycle() async throws {
        let camera = FakeCamera()
        let analyzer = FakeAnalyzer()
        let provider = makeProvider(camera: camera, analyzer: analyzer)

        await provider.handle(demandEvent(.face, 2))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face], fps: 15)))
        await provider.handle(try requestEvent(testRequest("blink-jump", [.face], fps: 30)))

        let snapshot = await provider.snapshot()
        #expect(snapshot.running[0].fps == 30)
        #expect(snapshot.running[0].requesters == ["blink-jump", "vibecheck"])
        // The model was constructed once and never torn down in between.
        #expect(analyzer.constructions == [[.face]])
        #expect(analyzer.releases.isEmpty)
    }

    @Test func publishedTopicsReachTheHostThroughTheDeadlinedSeam() async throws {
        let camera = FakeCamera()
        let publisher = SpyPublisher()
        let analyzer = FakeAnalyzer()
        let provider = VisionProvider(publisher: publisher, analyzer: analyzer, camera: camera)

        // The pump only runs once started; `events` finishing would shut the
        // provider down, so hand it a stream that stays open.
        let (events, continuation) = AsyncStream<VCEvent>.makeStream(of: VCEvent.self)
        await provider.start(events: events)
        await provider.handle(demandEvent(.face, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face], fps: 30)))

        // Drive one frame by hand: the fake camera delivers nothing on its own.
        let processor = await provider.frameProcessorForTesting
        camera.frameQueue.sync {
            processor.didOutput(makeTestPixelBuffer(), mirrored: true, deviceID: "builtin")
        }

        try await Task.sleep(for: .milliseconds(200))
        let published = await publisher.published
        #expect(published.map(\.topic) == ["vision.face.v1"])
        #expect(await provider.snapshot().counters.published == 1)

        continuation.finish()
        await provider.shutdown()
    }

    @Test func shutdownClosesTheCamera() async throws {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        await provider.handle(demandEvent(.face, 1))
        await provider.handle(try requestEvent(testRequest("vibecheck", [.face])))
        #expect(camera.isRunning)

        await provider.shutdown()
        #expect(camera.isRunning == false)
    }

    @Test func selectingAnUnknownCameraIsRejectedRatherThanSilentlyIgnored() async {
        let camera = FakeCamera()
        let provider = makeProvider(camera: camera)

        #expect(await provider.selectCamera(id: "not-a-camera") == false)
        #expect(await provider.selectCamera(id: "external"))
        #expect(camera.preferred == .some("external"))
    }
}
