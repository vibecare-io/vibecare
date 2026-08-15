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

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A fan-out regression (a continuation never yielded, or dropped before
/// yielding) would otherwise hang `await iterator.next()` — and `swift test`
/// — forever instead of failing. Every stream read below goes through this
/// so that failure mode becomes a fast, clear test failure. Takes the
/// STREAM (not a mutating `Iterator`) specifically so the read can run
/// inside a `@Sendable` `Task` closure without capturing a mutable local var
/// across the concurrency boundary.
private func firstEvent(from stream: AsyncStream<DetectionBroadcast>) async -> DetectionBroadcast? {
    for await value in stream { return value }
    return nil
}

private enum HostSinkTestError: Error { case timedOut }

private func withTimeout<T: Sendable>(
    seconds: Double = 3, _ body: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw HostSinkTestError.timedOut
        }
        guard let result = try await group.next() else {
            throw HostSinkTestError.timedOut
        }
        group.cancelAll()
        return result
    }
}

@Test func firedBroadcastsToEventsSubscribersEvenWithNoHostAttached() async throws {
    let prefs = try! AlertPrefsStore(directory: try! tempDir())
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())

    let stream = await sink.events()

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)

    let received = try await withTimeout { await firstEvent(from: stream) }
    #expect(received?.behavior == .nailBiting)
    #expect(received?.count == 1)
}

// Ruling T16c: `HostSink.fired` is the consumer `AlertPrefsStore.preferences(for:)`
// was always waiting for — before this, nothing in the package ever called
// it in production, so the "Advanced: Alert Appearance" editor persisted to
// `alert-prefs.json` and did nothing. These two tests are written as a
// PAIR deliberately: asserting only the fallback (as the version of
// `firedAlertsThroughTheAttachedHostWhenNotSnoozed` below used to, before
// this ruling) would pass just as happily against a `HostSink` that
// ignored `prefs` entirely — that was the actual bug. Only
// `firedUsesTheStoredAlertPreferencesWhenSet` can tell "reads prefs" apart
// from "always uses the built-in copy."

@Test func firedAlertsThroughTheAttachedHostWhenNotSnoozed() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .hairPulling, time: 1), count: 3, behavior: .hairPulling)

    #expect(await host.alerts.count == 1)
    let alert = try #require(await host.alerts.first)
    // A fresh `AlertPrefsStore` never had anything saved for this
    // behavior — `NotificationPreferences.default(for:)` leaves
    // `title`/`message` `nil` — so this is the FALLBACK path: the
    // built-in `behavior.label`/`behavior.nudge`, not a blank alert.
    #expect(alert.title == BFRBBehavior.hairPulling.label)
    #expect(alert.body == "\(BFRBBehavior.hairPulling.nudge) — 3rd nudge today")
    #expect(await host.publishedTopics == ["vibecheck.behavior_detected.v1"])
}

@Test func firedUsesTheStoredAlertPreferencesWhenSet() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    var all = await prefs.load()
    all[BFRBBehavior.nailBiting.rawValue]?.title = "Hands down!"
    all[BFRBBehavior.nailBiting.rawValue]?.message = "You've got this"
    try await prefs.save(all)

    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 5, behavior: .nailBiting)

    let alert = try #require(await host.alerts.first)
    #expect(alert.title == "Hands down!")
    // The `Ordinal.format(count)` suffix is appended to a user-authored
    // message too, not only the built-in fallback — see `HostSink.fired`'s
    // doc comment for why (the count is what makes the alert feel
    // responsive rather than a static, repeated banner).
    #expect(alert.body == "You've got this — 5th nudge today")
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

    await sink.fired(BFRBEvent(behavior: .nosePicking, time: 1), count: 1, behavior: .nosePicking)

    // Still broadcast to SSE: snoozing suppresses the popup, not the fact
    // that a detection happened.
    let received = try await withTimeout { await firstEvent(from: stream) }
    #expect(received?.behavior == .nosePicking)

    // But no alert reached the host.
    #expect(await host.alerts.isEmpty)
    #expect(await host.publishedTopics.isEmpty)
}

@Test func multipleEventsSubscribersEachGetTheirOwnCopy() async throws {
    let prefs = try! AlertPrefsStore(directory: try! tempDir())
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())

    let streamA = await sink.events()
    let streamB = await sink.events()

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)

    let a = try await withTimeout { await firstEvent(from: streamA) }
    let b = try await withTimeout { await firstEvent(from: streamB) }
    #expect(a?.behavior == .nailBiting)
    #expect(b?.behavior == .nailBiting)
}

// Ruling U1: the alert carries its own appearance, so the client can render
// this plugin's detection alert the way the user configured it without
// containing a line of vibecheck-specific code.
//
// The assertions below decode the blob back into `NotificationPreferences`
// and compare it to what the store holds. Asserting merely that
// `appearance != nil` would pass against a `HostSink` that sent a constant,
// or the wrong behavior's preferences, or an empty object — which are
// exactly the regressions that would leave the user staring at a plain
// banner again.

private func decodeAppearance(_ alert: VCAlert) throws -> NotificationPreferences {
    let raw = try #require(alert.appearance)
    return try JSONDecoder().decode(NotificationPreferences.self, from: Data(raw.utf8))
}

@Test func firedSendsTheStoredAppearanceForThatBehavior() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    var all = await prefs.load()
    all[BFRBBehavior.nailBiting.rawValue]?.width = 512
    all[BFRBBehavior.nailBiting.rawValue]?.screenBlurIntensity = .heavy
    all[BFRBBehavior.nailBiting.rawValue]?.autoDismissAfter = 42
    try await prefs.save(all)

    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)

    let decoded = try decodeAppearance(try #require(await host.alerts.first))
    #expect(decoded == (await prefs.preferences(for: .nailBiting)))
    #expect(decoded.width == 512)
    #expect(decoded.screenBlurIntensity == .heavy)
    #expect(decoded.autoDismissAfter == 42)
}

// Per-behavior, not per-plugin: the appearance sent must be the one for the
// behavior that actually fired. A `HostSink` that encoded a fixed default,
// or always read the first entry in the store, would pass the test above
// and fail this one.
@Test func firedSendsAPerBehaviorAppearance() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    var all = await prefs.load()
    all[BFRBBehavior.nailBiting.rawValue]?.width = 100
    all[BFRBBehavior.nosePicking.rawValue]?.width = 900
    try await prefs.save(all)

    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .nailBiting, time: 1), count: 1, behavior: .nailBiting)
    await sink.fired(BFRBEvent(behavior: .nosePicking, time: 2), count: 1, behavior: .nosePicking)

    let alerts = await host.alerts
    #expect(alerts.count == 2)
    #expect(try decodeAppearance(alerts[0]).width == 100)
    #expect(try decodeAppearance(alerts[1]).width == 900)
}

// Out of the box — no visit to the appearance editor — the alert must still
// carry the rich look, because that is what `AlertPrefsStore` seeds. If this
// regressed to "appearance only once customized", the default experience
// would be the plain banner this ruling exists to replace.
@Test func firedSendsTheDefaultAppearanceWithoutAnyCustomization() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .nosePicking, time: 1), count: 1, behavior: .nosePicking)

    let decoded = try decodeAppearance(try #require(await host.alerts.first))
    #expect(decoded == NotificationPreferences.default(for: .nosePicking))
    #expect(decoded.svgPath == "icons/\(BFRBBehavior.nosePicking.defaultIconId).svg")
    #expect(decoded.position == .center)
    #expect(decoded.screenBlurEnabled)
}

// The appearance must never displace the action buttons: the "Turn off"
// button is the user's way out of a camera they want stopped, and a
// prettier alert is not worth losing it.
@Test func firedKeepsItsActionsAlongsideTheAppearance() async throws {
    let prefs = try AlertPrefsStore(directory: try tempDir())
    let host = SpyAlertHost()
    let sink = HostSink(prefs: prefs, snooze: SnoozeGate())
    await sink.attach(host: host)

    await sink.fired(BFRBEvent(behavior: .hairPulling, time: 1), count: 1, behavior: .hairPulling)

    let alert = try #require(await host.alerts.first)
    #expect(alert.appearance != nil)
    #expect(alert.actions.map(\.url) == ["api/snooze?minutes=10", "api/config/disable"])
}

// The exact bytes on the wire, pinned. The macOS client pins the SAME
// literal in `PluginAlertAppearanceTests.swift` and asserts that it decodes
// into its own `NotificationPreferences`. Neither side can see the other's
// type, so these two literals ARE the cross-language contract: rename or
// retype a field on either side and exactly one of the two tests fails,
// which is the signal. Without them the failure mode is silent — the client
// decodes nothing, falls back to a plain banner, and nothing is red.
@Test func theEncodedAppearanceHasTheShapeTheClientDecodes() {
    let encoded = HostSink.encodeAppearance(.default(for: .nosePicking))
    #expect(encoded == #"{"autoDismissAfter":20,"height":220,"moveable":true,"position":"center","screenBlurEnabled":true,"screenBlurIntensity":"light","svgHeight":150,"svgPath":"icons\/nose-picking.svg","svgWidth":220,"width":450}"#)
}
