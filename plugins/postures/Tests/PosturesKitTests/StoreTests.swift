import Testing
import Foundation
@testable import PosturesKit

func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// Every persistence test here reads back through a SECOND store built on the
// same directory, never through the object that did the writing. An in-memory
// round trip would pass just as happily against a `save` that never touched
// the disk — which is the whole failure this plugin cannot afford, because
// `$VIBECARE_DATA_DIR` is the only place its state lives (no UserDefaults: a
// plugin binary has no bundle identifier).

@Test func configIsReadBackFromDiskAndNotFromTheWriter() async throws {
    let dir = try tempDir()
    let store = try ConfigStore(directory: dir)
    var c = PostureConfig.default
    c.enabled = true
    c.dwell = 300
    c.cooldown = 1800
    c.shoulderAngleThreshold = 12
    c.neckForwardThreshold = 0.25
    try await store.save(c)

    let reloaded = try ConfigStore(directory: dir)
    #expect(await reloaded.load() == c)
}

@Test func theConfigFileOnDiskIsTheJSONWeThinkItIs() async throws {
    // Reads the raw bytes, so a change to the persisted key names is a
    // deliberate act rather than something that silently resets everyone's
    // settings on upgrade.
    let dir = try tempDir()
    let store = try ConfigStore(directory: dir)
    try await store.save(.default)

    let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["enabled", "shoulderAngleThreshold",
                                 "neckForwardThreshold", "dwell", "cooldown"])
    #expect(object["dwell"] as? Double == 120)
    #expect(object["cooldown"] as? Double == 900)
    #expect(object["enabled"] as? Bool == false)
}

@Test func aMissingConfigFileYieldsDefaults() async throws {
    let store = try ConfigStore(directory: try tempDir())
    #expect(await store.load() == PostureConfig.default)
}

@Test func aCorruptConfigFileYieldsDefaultsRatherThanRefusingToStart() async throws {
    // Refusing to start because a config file got truncated would be an
    // unrequested exit, and five of those park the plugin in StateFailed
    // until a manual dashboard restart.
    let dir = try tempDir()
    try Data("{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
    let store = try ConfigStore(directory: dir)
    #expect(await store.load() == PostureConfig.default)
}

@Test func valuesAreClampedOnTheWayToDiskNotOnlyInTheUI() async throws {
    let dir = try tempDir()
    let store = try ConfigStore(directory: dir)
    var c = PostureConfig.default
    c.dwell = 0            // would fire on the first poor frame
    c.cooldown = 0         // and on every frame after it
    c.shoulderAngleThreshold = 900
    c.neckForwardThreshold = -5
    try await store.save(c)

    let reloaded = try ConfigStore(directory: dir)
    let loaded = await reloaded.load()
    #expect(loaded.dwell == 5)
    #expect(loaded.cooldown == 30)
    #expect(loaded.shoulderAngleThreshold == 45)
    #expect(loaded.neckForwardThreshold == 0.02)
}

@Test func aNonFiniteThresholdFallsBackToTheDefaultRatherThanClamping() {
    // `min`/`max` leave NaN untouched — every comparison against it is false
    // — and a NaN threshold would make every fault test false forever, so the
    // plugin would look healthy and never nudge again. Infinity would clamp
    // correctly, but `isFinite` rejects it too and the default is a saner
    // answer than "the widest threshold the UI allows" for a value that was
    // clearly never typed by a human.
    var c = PostureConfig.default
    c.shoulderAngleThreshold = .nan
    c.neckForwardThreshold = .infinity
    c.dwell = .nan
    c.cooldown = -.infinity
    let clamped = c.clamped()
    #expect(clamped.shoulderAngleThreshold == PostureConfig.default.shoulderAngleThreshold)
    #expect(clamped.neckForwardThreshold == PostureConfig.default.neckForwardThreshold)
    #expect(clamped.dwell == PostureConfig.default.dwell)
    #expect(clamped.cooldown == PostureConfig.default.cooldown)
    // And every one of them stays usable, which is the point.
    #expect(clamped.dwell.isFinite && clamped.cooldown.isFinite)
}

@Test func aHandEditedConfigFileIsClampedOnLoadToo() async throws {
    let dir = try tempDir()
    try Data(#"{"enabled":true,"shoulderAngleThreshold":0,"neckForwardThreshold":0.2,"dwell":1,"cooldown":1}"#.utf8)
        .write(to: dir.appendingPathComponent("config.json"))
    let store = try ConfigStore(directory: dir)
    let loaded = await store.load()
    #expect(loaded.enabled)         // the user's real intent survives
    #expect(loaded.dwell == 5)
    #expect(loaded.cooldown == 30)
    #expect(loaded.shoulderAngleThreshold == 1)
}

// MARK: - Counts

@Test func nudgeCountsAreDateKeyedAndReadBackFromDisk() async throws {
    let dir = try tempDir()
    let store = try NudgeCountsStore(directory: dir)
    #expect(try await store.increment(on: "2026-08-15") == 1)
    #expect(try await store.increment(on: "2026-08-15") == 2)
    #expect(try await store.increment(on: "2026-08-16") == 1)

    let reloaded = try NudgeCountsStore(directory: dir)
    #expect(await reloaded.count(on: "2026-08-15") == 2)
    #expect(await reloaded.count(on: "2026-08-16") == 1)
    // Yesterday's total must not leak into today's copy: "3rd nudge today"
    // is the only count this plugin ever states.
    #expect(await reloaded.count(on: "2026-08-14") == 0)
}

@Test func theCountsFileOnDiskIsADayKeyedObject() async throws {
    let dir = try tempDir()
    let store = try NudgeCountsStore(directory: dir)
    try await store.increment(on: "2026-08-15")
    try await store.increment(on: "2026-08-15")

    let data = try Data(contentsOf: dir.appendingPathComponent("counts.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
    #expect(object == ["2026-08-15": 2])
}

@Test func aCorruptCountsFileStartsFromZeroRatherThanThrowing() async throws {
    let dir = try tempDir()
    try Data("[]".utf8).write(to: dir.appendingPathComponent("counts.json"))
    let store = try NudgeCountsStore(directory: dir)
    #expect(await store.count(on: "2026-08-15") == 0)
    #expect(try await store.increment(on: "2026-08-15") == 1)
}

@Test func dayKeysAreLocalCalendarDaysInAFixedFormat() {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 15
    components.hour = 23
    components.minute = 59
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: components)!
    // Local time, because that is how a user thinks about "today" — 11:59 pm
    // is still today even where UTC has already rolled over.
    #expect(NudgeCountsStore.dayKey(date) == "2026-08-15")
}

// MARK: - Snooze

@Test func snoozeSuppressesUntilItsDeadlineAndNotThroughIt() async {
    let gate = SnoozeGate()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 30, now: t0)
    #expect(await gate.isActive(now: t0))
    #expect(await gate.isActive(now: t0.addingTimeInterval(1799)))
    // Strict `<`: the instant the deadline arrives it is over.
    #expect(await gate.isActive(now: t0.addingTimeInterval(1800)) == false)
    #expect(await gate.deadline() == t0.addingTimeInterval(1800))
}

@Test func aNonPositiveSnoozeClearsRatherThanBackdating() async {
    let gate = SnoozeGate()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    await gate.snooze(minutes: 30, now: t0)
    await gate.snooze(minutes: 0, now: t0)
    #expect(await gate.isActive(now: t0) == false)
    #expect(await gate.deadline() == nil)
}
