import Testing
import Foundation
import VCKStubs
import VCPluginSDK
@testable import PosturesKit

/// A clock the test moves by hand. Every timing decision in `PostureMonitor`
/// goes through the injected `now` closure precisely so none of these tests
/// has to sleep.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_755_000_000)) { self.t = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return t
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); t += seconds; lock.unlock()
    }
}

private func signalsEvent(seq: UInt64, shoulderAngle: Float? = nil,
                          neckForward: Float? = nil) -> VCEvent {
    var s = VCTSignals()
    var header = VCTHeader()
    header.seq = seq
    s.header = header
    if let shoulderAngle { s.shoulderAngle = shoulderAngle }
    if let neckForward { s.neckForward = neckForward }
    return VCEvent(topic: VisionRequest.signalsTopic,
                   payload: (try? s.serializedData()) ?? Data(), ts: nil)
}

private func demandEvent(topic: String, subscribers: Int) -> VCEvent {
    let payload = (try? JSONEncoder().encode(VCDemand(topic: topic, subscribers: subscribers))) ?? Data()
    return VCEvent(topic: VCTopicDemand, payload: payload, ts: nil)
}

private struct Rig {
    let monitor: PostureMonitor
    let host: SpyHost
    let clock: FakeClock
    let snooze: SnoozeGate
    let config: ConfigStore
}

private func makeRig(_ config: PostureConfig = {
    var c = PostureConfig.default
    c.enabled = true
    c.dwell = 120
    c.cooldown = 900
    return c
}()) async throws -> Rig {
    let dir = try tempDir()
    let configStore = try ConfigStore(directory: dir)
    try await configStore.save(config)
    let counts = try NudgeCountsStore(directory: dir)
    let snooze = SnoozeGate()
    let clock = FakeClock()
    let host = SpyHost()
    let requester = VisionRequester(requester: "postures")
    let monitor = PostureMonitor(config: configStore, counts: counts, snooze: snooze,
                                 requester: requester,
                                 initial: await configStore.load(),
                                 now: { clock.now })
    await monitor.attach(host: host)
    return Rig(monitor: monitor, host: host, clock: clock, snooze: snooze, config: configStore)
}

/// Feeds `count` poor-posture frames at 2 fps, advancing the clock between
/// them exactly as vision would.
private func feedPoor(_ rig: Rig, seconds: TimeInterval, startingSeq: UInt64 = 1) async {
    var seq = startingSeq
    var elapsed = 0.0
    while elapsed <= seconds {
        await rig.monitor.handle(signalsEvent(seq: seq, neckForward: 0.6))
        rig.clock.advance(0.5)
        elapsed += 0.5
        seq += 1
    }
}

// MARK: - The nudge

@Test func sustainedPoorPostureFiresExactlyOneAlert() async throws {
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)

    let alerts = await rig.host.alerts
    #expect(alerts.count == 1)
    let alert = try #require(alerts.first)
    #expect(alert.title == "Sit up")
    #expect(alert.level == "warn")
    #expect(alert.body.contains("head has been forward"))
    #expect(alert.body.contains("1st nudge today"))
}

@Test func theAlertCarriesASnoozeActionThatAcceptsAPlainGET() async throws {
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)
    let alert = try #require(await rig.host.alerts.first)

    let snooze = try #require(alert.actions.first { $0.label.hasPrefix("Snooze") })
    // Plugin-RELATIVE: core routes it to /p/postures/<url>. An absolute URL
    // would require the plugin to know the port core assigned it.
    #expect(snooze.url == "api/snooze?minutes=30")
    #expect(!snooze.url.hasPrefix("/"))
    #expect(!snooze.url.contains("://"))
    // Both action targets are registered as GET-or-POST handlers in API.swift,
    // because a client following an action URL issues a GET.
    #expect(alert.actions.contains { $0.url == "api/config/disable" })
}

@Test func theAlertCarriesATypedAppearanceWithARelativeIconPath() async throws {
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)
    let alert = try #require(await rig.host.alerts.first)

    // The wire field is a JSON string; decoding it back through the SDK type
    // is what proves the plugin speaks the shell's vocabulary rather than one
    // of its own — a blob matching none of these keys is rejected outright
    // and renders as the plain banner.
    let raw = try #require(alert.appearance)
    let decoded = try JSONDecoder().decode(VCAlertAppearance.self, from: Data(raw.utf8))
    #expect(decoded.svgPath == "icons/posture.svg")
    #expect(decoded.svgWidth == 220)
    #expect(decoded.svgHeight == 150)
    #expect(decoded.position == .topRight)
    #expect(decoded.moveable == true)
    #expect(decoded.autoDismissAfter == 20)
    // The icon this points at must be one `/icons/` will actually serve: a
    // relative svgPath that fails to load downgrades the WHOLE alert to a
    // plain banner, taking the action buttons with it.
    #expect(PostureIcon.all.contains("posture"))
}

@Test func theNudgeIsCountedAndPersistedForTheDay() async throws {
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)

    let state = await rig.monitor.snapshot()
    #expect(state.nudgesToday == 1)
    #expect(state.lastNudgeAt != nil)
    #expect(state.day == NudgeCountsStore.dayKey(rig.clock.now))
}

@Test func aSecondNudgeWaitsOutTheCooldownAndThenCountsUp() async throws {
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)
    #expect(await rig.host.alerts.count == 1)

    // Fifteen more minutes of continuous slouching, at 2 fps.
    await feedPoor(rig, seconds: 900, startingSeq: 1000)
    let alerts = await rig.host.alerts
    #expect(alerts.count == 2)
    #expect(alerts[1].body.contains("2nd nudge today"))
    #expect(await rig.monitor.snapshot().nudgesToday == 2)
}

@Test func goodPostureNeverNudgesHoweverLongItLasts() async throws {
    let rig = try await makeRig()
    var seq: UInt64 = 1
    for _ in 0..<600 {
        await rig.monitor.handle(signalsEvent(seq: seq, shoulderAngle: 1, neckForward: 0.02))
        rig.clock.advance(0.5)
        seq += 1
    }
    #expect(await rig.host.alerts.isEmpty)
    #expect(await rig.monitor.snapshot().verdict == "good")
}

// MARK: - Missing signals

@Test func framesWithNoMeasurementNeverNudgeAndReadAsUnknown() async throws {
    // The absent-is-not-zero rule at the top level: an hour of empty signals
    // frames is a provider that is running but measuring nothing, and it must
    // produce neither a nudge (absent read as a huge value) nor a clean bill
    // of health (absent read as zero).
    let rig = try await makeRig()
    var seq: UInt64 = 1
    for _ in 0..<600 {
        await rig.monitor.handle(signalsEvent(seq: seq))
        rig.clock.advance(0.5)
        seq += 1
    }
    #expect(await rig.host.alerts.isEmpty)

    let state = await rig.monitor.snapshot()
    #expect(state.verdict == "unknown")
    // And the readout says so rather than reporting a fabricated 0.
    let reading = try #require(state.reading)
    #expect(reading.shoulderAngle == nil)
    #expect(reading.neckForward == nil)
    #expect(state.notes.contains { $0.contains("neither shoulder_angle nor neck_forward") })
}

@Test func aGapInTheStreamResetsTheDwellRatherThanNudgingOnWake() async throws {
    // The laptop slept mid-slouch. Without the gap guard, the first frame
    // after waking would hand the policy a two-hour-old run and fire
    // instantly, describing a slouch that happened with the lid shut.
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 110)          // 10 s short of the dwell
    #expect(await rig.host.alerts.isEmpty)

    rig.clock.advance(7200)                    // two hours asleep
    await rig.monitor.handle(signalsEvent(seq: 9000, neckForward: 0.6))
    #expect(await rig.host.alerts.isEmpty)

    // And the run genuinely restarts rather than merely being delayed.
    await feedPoor(rig, seconds: 60, startingSeq: 9001)
    #expect(await rig.host.alerts.isEmpty)
    await feedPoor(rig, seconds: 70, startingSeq: 10000)
    #expect(await rig.host.alerts.count == 1)
}

@Test func anUndecodablePayloadIsDroppedRatherThanCrashingTheEventLoop() async throws {
    let rig = try await makeRig()
    let junk = VCEvent(topic: VisionRequest.signalsTopic,
                       payload: Data([0xff, 0xff, 0xff, 0xff]), ts: nil)
    await rig.monitor.handle(junk)
    await feedPoor(rig, seconds: 130)
    #expect(await rig.host.alerts.count == 1)
}

// MARK: - Enable / disable

@Test func aDisabledPluginUpdatesItsReadoutButNeverNudges() async throws {
    var off = PostureConfig.default
    off.enabled = false
    let rig = try await makeRig(off)
    await feedPoor(rig, seconds: 400)

    #expect(await rig.host.alerts.isEmpty)
    let state = await rig.monitor.snapshot()
    // The reading is still shown: another consumer may be driving vision, and
    // seeing what their posture actually looks like is how a user decides
    // whether to switch this on.
    #expect(state.verdict == "poor")
    #expect(state.poorForSeconds == nil)     // no run is being accumulated
    #expect(state.notes.contains { $0.contains("Postures is off") })
}

@Test func applyingAConfigRetractsOrAssertsTheVisionRequest() async throws {
    let rig = try await makeRig()
    var off = await rig.config.load()
    off.enabled = false
    try await rig.config.save(off)
    await rig.monitor.apply(await rig.config.load())

    let requests = await rig.host.requests()
    #expect(requests.last?.topics.isEmpty == true)
    #expect(await rig.monitor.snapshot().enabled == false)
}

@Test func aConfigChangeClearsTheRunButNotTheCooldown() async throws {
    // Otherwise nudging the sensitivity slider would be a way to bypass the
    // fifteen-minute cooldown and get told off again immediately.
    let rig = try await makeRig()
    await feedPoor(rig, seconds: 130)
    #expect(await rig.host.alerts.count == 1)

    var c = await rig.config.load()
    c.shoulderAngleThreshold = 20
    try await rig.config.save(c)
    await rig.monitor.apply(await rig.config.load())

    await feedPoor(rig, seconds: 300, startingSeq: 5000)
    #expect(await rig.host.alerts.count == 1)
}

// MARK: - Snooze

@Test func aSnoozeSuppressesBothTheAlertAndTheCount() async throws {
    // "Nudges today" has to mean nudges the user actually received, or the
    // number in the UI and the ordinal in the alert copy are both lies.
    let rig = try await makeRig()
    await rig.snooze.snooze(minutes: 30, now: rig.clock.now)
    await feedPoor(rig, seconds: 130)

    #expect(await rig.host.alerts.isEmpty)
    let state = await rig.monitor.snapshot()
    #expect(state.nudgesToday == 0)
    #expect(state.snoozedUntil != nil)
}

@Test func theCooldownStillRunsThroughASnoozeSoNothingBacklogs() async throws {
    let rig = try await makeRig()
    await rig.snooze.snooze(minutes: 5, now: rig.clock.now)
    await feedPoor(rig, seconds: 130)          // fires, suppressed
    #expect(await rig.host.alerts.isEmpty)

    // The snooze lapses long before the cooldown does, and no backlog is
    // released when it does.
    await feedPoor(rig, seconds: 400, startingSeq: 5000)
    #expect(await rig.host.alerts.isEmpty)
    await feedPoor(rig, seconds: 500, startingSeq: 9000)
    #expect(await rig.host.alerts.count == 1)
}

// MARK: - Demand and the readout

@Test func aDemandBurstReassertsTheVisionRequest() async throws {
    // A demand burst is the only observable signal a plugin gets that its
    // Register stream came back, so it is where the request is re-asserted.
    let rig = try await makeRig()
    let before = await rig.host.requests().count
    await rig.monitor.handle(demandEvent(topic: VisionRequest.topic, subscribers: 1))
    #expect(await rig.host.requests().count == before + 1)
}

@Test func zeroSubscribersOnTheRequestTopicIsSurfacedNotSwallowed() async throws {
    let rig = try await makeRig()
    await rig.monitor.handle(demandEvent(topic: VisionRequest.topic, subscribers: 0))
    let state = await rig.monitor.snapshot()
    #expect(state.request.subscribers[VisionRequest.topic] == 0)
    #expect(state.notes.contains { $0.contains("Nothing is subscribed to") })
}

@Test func havingReceivedNoFramesAtAllIsSaidOutLoud() async throws {
    // Subscribed-but-receiving-nothing is indistinguishable from working
    // normally, and a readout that says so is the only thing that can tell
    // them apart.
    let rig = try await makeRig()
    let state = await rig.monitor.snapshot()
    #expect(state.reading == nil)
    #expect(state.notes.contains { $0.contains("No vision frames received yet") })
}

@Test func theStateSnapshotSerializesWithAbsentMeasurementsOmitted() async throws {
    let rig = try await makeRig()
    await rig.monitor.handle(signalsEvent(seq: 1, neckForward: 0.6))
    let data = try JSONEncoder().encode(await rig.monitor.snapshot())
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let reading = try #require(object["reading"] as? [String: Any])
    let neck = try #require(reading["neckForward"] as? Double)
    #expect(abs(neck - 0.6) < 1e-6)
    // Absent, not zero — the UI tests for the key's presence, and a 0 here
    // would read as perfectly level shoulders.
    #expect(reading["shoulderAngle"] == nil)
}

// MARK: - Copy

@Test func theNudgeCopyNamesWhatWasActuallyMeasured() {
    #expect(NudgeCopy.body(faults: [.unevenShoulders], sustained: 180, count: 1)
            == "Your shoulders have been uneven for 3 minutes — 1st nudge today")
    #expect(NudgeCopy.body(faults: [.forwardHead], sustained: 121, count: 2)
            == "Your head has been forward of your shoulders for 2 minutes — 2nd nudge today")
    #expect(NudgeCopy.body(faults: [.unevenShoulders, .forwardHead], sustained: 60, count: 3)
            == "You've been slouching for 60 seconds — 3rd nudge today")
}

@Test func ordinalsFollowEnglishRulesIncludingTheTeens() {
    #expect(NudgeCopy.ordinal(1) == "1st")
    #expect(NudgeCopy.ordinal(2) == "2nd")
    #expect(NudgeCopy.ordinal(3) == "3rd")
    #expect(NudgeCopy.ordinal(4) == "4th")
    #expect(NudgeCopy.ordinal(11) == "11th")
    #expect(NudgeCopy.ordinal(12) == "12th")
    #expect(NudgeCopy.ordinal(13) == "13th")
    #expect(NudgeCopy.ordinal(21) == "21st")
    #expect(NudgeCopy.ordinal(111) == "111th")
}

@Test func durationsRoundDownSoTheAlertNeverOverclaims() {
    #expect(NudgeCopy.duration(0.9) == "0 seconds")
    #expect(NudgeCopy.duration(1) == "1 second")
    #expect(NudgeCopy.duration(89.9) == "89 seconds")
    #expect(NudgeCopy.duration(90) == "1 minute")
    #expect(NudgeCopy.duration(179) == "2 minutes")
}
