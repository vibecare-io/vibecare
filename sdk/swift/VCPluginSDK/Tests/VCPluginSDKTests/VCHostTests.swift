import Testing
import Foundation
@testable import VCPluginSDK

@Test func cleanStreamEndIsTreatedAsAReconnect() {
    // rpc.go:146-149 returns nil when a non-superseded cancel closes the
    // subscriber channel. In grpc-swift that surfaces as an AsyncSequence
    // that simply finishes — nothing thrown. A do/catch-driven loop would
    // fall out and never reconnect again.
    #expect(VCSessionOutcome.classify(error: nil) == .reconnect)
    #expect(VCSessionOutcome.classify(error: VCHostError.streamEnded) == .reconnect)
}

@Test func shutdownRequestIsTheOnlyNonReconnectOutcome() {
    #expect(VCSessionOutcome.classify(error: VCHostError.shutdownRequested) == .stop)
    // A registration core will never accept still reconnects: a core restart
    // with a corrected manifest must recover without a plugin restart.
    #expect(VCSessionOutcome.classify(error: VCHostError.registrationRejected("no such plugin")) == .reconnect)
    #expect(VCSessionOutcome.classify(error: VCHostError.readyTimeout) == .reconnect)
}

@Test func healthBodyOmitsDetailWhenOk() throws {
    // health.go:179-181 force-clears detail on any transition to up, so a
    // detail string alongside "ok" is silently discarded. Do not emit one.
    let ok = VCHealthBody(status: "ok", detail: "camera warming")
    let encoded = String(decoding: try JSONEncoder().encode(ok.normalized()), as: UTF8.self)
    #expect(encoded.contains("\"status\":\"ok\""))
    #expect(!encoded.contains("camera warming"))

    let degraded = VCHealthBody(status: "degraded", detail: "camera unavailable")
    let d = String(decoding: try JSONEncoder().encode(degraded.normalized()), as: UTF8.self)
    #expect(d.contains("camera unavailable"))
}

// The shutdown-hook drain is bounded by VCShutdownLatch, so a hook that hangs
// costs the drain budget rather than the whole of core's 5s SIGTERM->SIGKILL
// grace. A task group cannot express this: it awaits every child before
// returning, so it can never abandon work that ignores cancellation. These
// two tests pin both sides of that.

@Test func aHookThatNeverFinishesIsAbandonedAtItsBudget() async {
    let latch = VCShutdownLatch()
    // Nothing ever calls complete() — this stands in for the wedged hook.
    let started = ContinuousClock.now
    let finished = await latch.waitForCompletion(upTo: .milliseconds(250))
    let elapsed = ContinuousClock.now - started

    #expect(finished == false)
    #expect(elapsed >= .milliseconds(250))
    // The point of the whole exercise: waiting ended on the budget, not on
    // the hook.
    #expect(elapsed < .seconds(2))
}

@Test func aHookThatFinishesInTimeIsReportedAsCompleted() async {
    let latch = VCShutdownLatch()
    Task { await latch.complete() }
    // A budget far longer than the work, to prove the wait ends on the work.
    let started = ContinuousClock.now
    #expect(await latch.waitForCompletion(upTo: .seconds(30)) == true)
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test func completionBeforeTheWaitStartsIsNotLost() async {
    // The hook can finish before the drain gets around to waiting on it; the
    // latch must not then block for the full budget.
    let latch = VCShutdownLatch()
    await latch.complete()
    let started = ContinuousClock.now
    #expect(await latch.waitForCompletion(upTo: .seconds(30)) == true)
    #expect(ContinuousClock.now - started < .seconds(1))
}

@Test func demandPayloadDecodes() throws {
    let json = Data(#"{"topic":"sensor.landmarks.v1","subscribers":2}"#.utf8)
    let d = try JSONDecoder().decode(VCDemand.self, from: json)
    #expect(d.topic == "sensor.landmarks.v1")
    #expect(d.subscribers == 2)
    #expect(VCTopicDemand == "_core.demand.v1")
}

// `appearance` is optional in the WIRE sense, not merely "may be empty".
// These two pin both halves of that, because the difference is invisible in
// the encoded bytes of a happy-path alert and only shows up as a client
// silently restyling every alert that never asked to be styled.

@Test func alertOmitsAppearanceWhenTheCallerSetNone() {
    let req = VCHost.makeAlertReq(VCAlert(title: "T", body: "B", level: "warn",
                                         actions: [VCAlertAction(label: "Off", url: "api/off")]))
    #expect(req.hasAppearance == false)
    #expect(req.title == "T")
    #expect(req.actions.map(\.url) == ["api/off"])
}

@Test func alertCarriesAppearanceVerbatimWhenSet() {
    // Nested quotes and a multi-byte character: anything that re-encoded
    // the blob rather than passing it through would change these bytes.
    let blob = #"{"width":450,"title":"say \"hi\" 💛"}"#
    let req = VCHost.makeAlertReq(VCAlert(title: "T", body: "B", appearance: blob))
    #expect(req.hasAppearance)
    #expect(req.appearance == blob)
}

// An explicitly-empty appearance is still an appearance. A `!isEmpty` guard
// in the mapping would pass every other test in this file.
@Test func alertKeepsAnExplicitlyEmptyAppearance() {
    let req = VCHost.makeAlertReq(VCAlert(title: "T", body: "B", appearance: ""))
    #expect(req.hasAppearance)
}
