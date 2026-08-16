import Foundation
import Testing
@testable import BlinkJumpKit

/// Drains an SSE stream that has already been finished by `detach`, so these
/// tests never race a timer.
private func drain(_ stream: AsyncStream<GameEvent>) async -> [GameEvent] {
    var events: [GameEvent] = []
    for await event in stream { events.append(event) }
    return events
}

private extension Array where Element == GameEvent {
    var blinks: [BlinkUpdate] {
        compactMap { if case .blink(let b) = $0 { return b } else { return nil } }
    }
    var meters: [MeterUpdate] {
        compactMap { if case .meter(let m) = $0 { return m } else { return nil } }
    }
}

@Test func openingTheGameRequestsSignalsAndClosingItReleasesThem() async {
    // The demand story, end to end through the pieces the HTTP layer wires
    // together: an SSE client attaching is what asks for a camera.
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)

    let (id, stream) = await engine.attach()
    #expect(await requester.intent.topics == [VisionTopic.signals, VisionTopic.face],
            "signals are arithmetic, so asking for them without asking for the face model they are computed from yields ear_l absent on every frame — see VisionRequester.playingTopics")
    #expect(await engine.playerCount == 1)

    await engine.detach(id)
    #expect(await requester.intent.topics == [], "the game being closed must release the camera")
    #expect(await engine.playerCount == 0)

    _ = await drain(stream)
}

@Test func aBlinkReachesTheStreamAsAJump() async {
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)
    let (id, stream) = await engine.attach()

    for (t, ear) in [(0.00, 0.30), (0.05, 0.10), (0.10, 0.09), (0.16, 0.31)] {
        await engine.ingest(sample: VisionSignalSample(earL: ear, earR: ear, seq: 0), at: t)
    }
    await engine.detach(id)

    let events = await drain(stream)
    #expect(events.blinks.count == 1)
    #expect(events.blinks.first?.index == 1)
    #expect(events.blinks.first?.closureMs == 110)
}

@Test func theMeterCarriesTheLiveEarValuesAndTheBand() async {
    // A player must be able to see the detector working when it is NOT
    // triggering, which is the only way to tell "my threshold is wrong" apart
    // from "this plugin is broken".
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: BlinkThresholds(close: 0.20, hysteresis: 0.05), requester: requester)
    let (id, stream) = await engine.attach()

    await engine.ingest(sample: VisionSignalSample(earL: 0.34, earR: 0.30, seq: 7), at: 0)
    await engine.detach(id)

    let last = await drain(stream).meters.last
    #expect(last?.earL == 0.34)
    #expect(last?.earR == 0.30)
    #expect(abs((last?.ear ?? 0) - 0.32) < 1e-9)
    #expect(last?.tracking == true)
    #expect(last?.phase == "open")
    #expect(last?.closeThreshold == 0.20)
    #expect(abs((last?.openThreshold ?? 0) - 0.25) < 1e-9)
    #expect(last?.seq == 7)
}

@Test func absentEarsArriveAtThePageAsPausedNotAsAShutEye() async {
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)
    let (id, stream) = await engine.attach()

    await engine.ingest(sample: VisionSignalSample(earL: 0.31, earR: 0.31), at: 0)
    // An empty signals message: a real frame in which nothing was measured.
    await engine.ingest(sample: VisionSignalSample(earL: nil, earR: nil), at: 0.1)
    await engine.detach(id)

    let meters = await drain(stream).meters
    #expect(meters.last?.tracking == false)
    #expect(meters.last?.ear == nil)
    #expect(meters.last?.earL == nil)
    #expect(meters.last?.phase == "absent")
    #expect(await engine.snapshot().blinks == 0)
}

@Test func droppedFramesShowUpInTheReadout() async {
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)

    await engine.ingest(sample: VisionSignalSample(earL: 0.30, earR: 0.30, seq: 10), at: 0)
    await engine.ingest(sample: VisionSignalSample(earL: 0.30, earR: 0.30, seq: 14), at: 0.1)

    let snapshot = await engine.snapshot()
    #expect(snapshot.droppedFrames == 3)
    #expect(snapshot.signalsReceived == 2)
}

@Test func aPayloadThatIsNotSignalsIsCountedRatherThanLogged() async {
    // At 30 fps, logging a contract mismatch per frame would write 30 lines a
    // second into core's captured stderr forever.
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)

    await engine.ingest(payload: Data([0x0A, 0x05]))
    let snapshot = await engine.snapshot()
    #expect(snapshot.undecodableSignals == 1)
    #expect(snapshot.signalsReceived == 0)
}

@Test func recalibrationAppliesToTheLiveDetector() async {
    let requester = VisionRequester(requester: "blink-jump")
    let engine = BlinkEngine(thresholds: .default, requester: requester)

    await engine.apply(thresholds: BlinkThresholds(close: 0.12, hysteresis: 0.03))
    let snapshot = await engine.snapshot()
    #expect(snapshot.thresholds.close == 0.12)
    #expect(snapshot.phase == "absent")
}

// MARK: - The diagnostic note

@Test func theNoteNamesTheMostLikelyWiringMistake() {
    // Requesting into a void: subscribed, publishing, and receiving nothing —
    // which looks exactly like a broken bus from every other angle.
    let detector = BlinkEngine.Snapshot(
        phase: "absent", tracking: false, ear: nil, blinks: 0, players: 1,
        signalsReceived: 0, lastSignalAt: nil, droppedFrames: 0,
        undecodableSignals: 0, thresholds: .default
    )
    let request = VisionRequester.Snapshot(
        players: 1, topics: [VisionTopic.signals], fps: 30, ttlSeconds: 30,
        assertions: 2, lastAssertedAt: Date(), lastError: nil,
        providerSubscribers: 0, hostAttached: true
    )
    #expect(diagnosticNote(detector: detector, request: request, now: Date())
        .contains("does not appear to be running"))
}

@Test func theNoteSaysWhyTheCameraIsOffWhenNobodyIsPlaying() {
    let detector = BlinkEngine.Snapshot(
        phase: "absent", tracking: false, ear: nil, blinks: 0, players: 0,
        signalsReceived: 0, lastSignalAt: nil, droppedFrames: 0,
        undecodableSignals: 0, thresholds: .default
    )
    let request = VisionRequester.Snapshot(
        players: 0, topics: [], fps: 30, ttlSeconds: 30,
        assertions: 1, lastAssertedAt: Date(), lastError: nil,
        providerSubscribers: 1, hostAttached: true
    )
    #expect(diagnosticNote(detector: detector, request: request, now: Date())
        .contains("Nobody is playing"))
}
