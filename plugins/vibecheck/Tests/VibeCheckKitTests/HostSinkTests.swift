import Testing
import Foundation
import VCPluginSDK
@testable import VibeCheckKit

// `HostSink` is the production `DetectionSink`: it fans a confirmed
// detection out to every `/api/events` SSE subscriber via `events()`, then
// — unless `SnoozeGate` says otherwise — alerts through core and publishes
// to the bus. It is constructed before `VCHost` exists (routes, and the
// `/api/state` polling they answer, must be live before `VCHost.connect()`
// can even be called — see main.swift's composition-root ordering comment),
// so the host is attached later via `attach(host:)` and may be nil when
// `fired` runs.
//
// `VCHost` itself dials a real gRPC socket and cannot be constructed in a
// unit test, so `HostSink` talks to it through the local `AlertHost`
// protocol seam instead — `VCHost` conforms structurally with no changes of
// its own. `SpyAlertHost` below is the fake that makes the snooze gating
// genuinely observable, not just "didn't crash": without this seam there
// would be no way to tell "alert suppressed because snoozed" apart from
// "alert suppressed because host was nil," which is exactly the kind of
// can't-fail guard this plan's reviews have flagged before.

private actor SpyAlertHost: AlertHost {
    private(set) var alerts: [VCAlert] = []
    private(set) var publishedTopics: [String] = []

    func alert(_ a: VCAlert) async throws {
        alerts.append(a)
    }

    func publish(topic: String, payload: Data) async throws {
        publishedTopics.append(topic)
    }
}

private func face() -> FaceGeometry {
    FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                 nose: CGPoint(x: 0.5, y: 0.5),
                 mouth: CGPoint(x: 0.5, y: 0.62))
}

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func firedBroadcastsToEventsSubscribersEvenWithNoHostAttached() async {
    let prefs = try! AlertPrefsStore(directory: try! tempDir())
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())

    let stream = await sink.events()
    var iterator = stream.makeAsyncIterator()

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)

    let received = await iterator.next()
    #expect(received?.behavior == .nailBiting)
    #expect(received?.count == 1)
}

@Test func firedAlertsThroughTheAttachedHostWhenNotSnoozed() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .hairPulling, time: 1), count: 3, behavior: .hairPulling)

    #expect(await host.alerts.count == 1)
    #expect(await host.alerts.first?.title == BFRBBehavior.hairPulling.label)
    #expect(await host.publishedTopics == ["vibecheck.behavior_detected.v1"])
}

@Test func firedSkipsTheAlertWhileSnoozedButStillBroadcastsToEvents() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    let host = SpyAlertHost()
    let snooze = SnoozeGate()
    // `fired` checks the snooze against the LIVE clock (`SnoozeGate.isActive`'s
    // default `now: Date()`), so the snooze set here has to be relative to
    // real "now" too — not a fixed synthetic instant, which is what
    // `SnoozeGateTests` uses for determinism but would read as already
    // lapsed by billions of seconds against the real clock `fired` checks.
    await snooze.snooze(minutes: 10)

    let sink = HostSink(prefs: prefs, snooze: snooze)
    await sink.attach(host: host)

    let stream = await sink.events()
    var iterator = stream.makeAsyncIterator()

    await sink.fired(BFRBEvent(behavior: .nosePicking, time: 1), count: 1, behavior: .nosePicking)

    // Still broadcast to SSE: snoozing suppresses the popup, not the fact
    // that a detection happened.
    let received = await iterator.next()
    #expect(received?.behavior == .nosePicking)

    // But no alert reached the host.
    #expect(await host.alerts.isEmpty)
    #expect(await host.publishedTopics.isEmpty)
}

@Test func multipleEventsSubscribersEachGetTheirOwnCopy() async {
    let prefs = try! AlertPrefsStore(directory: try! tempDir())
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())

    let streamA = await sink.events()
    let streamB = await sink.events()
    var a = streamA.makeAsyncIterator()
    var b = streamB.makeAsyncIterator()

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)

    #expect(await a.next()?.behavior == .nailBiting)
    #expect(await b.next()?.behavior == .nailBiting)
}
