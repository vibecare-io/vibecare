import Testing
import Foundation
@testable import VibeCheckKit

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func configRoundTripsThroughDisk() async throws {
    let dir = try tempDir()
    let store = try ConfigStore(directory: dir)
    var c = VibeCheckConfig.default
    c.sensitivity = 0.7
    c.enabledBehaviors = ["nailBiting"]
    try await store.save(c)

    // A fresh store, so this reads the file rather than an in-memory cache.
    // An in-memory round trip would pass even against a no-op flush.
    let reloaded = try ConfigStore(directory: dir)
    #expect(await reloaded.load().sensitivity == 0.7)
    #expect(await reloaded.load().enabledBehaviors == ["nailBiting"])
}

@Test func missingConfigFileYieldsDefaults() async throws {
    let store = try ConfigStore(directory: try tempDir())
    #expect(await store.load() == VibeCheckConfig.default)
}

@Test func corruptConfigFileYieldsDefaultsRatherThanCrashing() async throws {
    let dir = try tempDir()
    try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
    let store = try ConfigStore(directory: dir)
    // Refusing to start because a config file got truncated would be an
    // unrequested exit — five of those park the plugin in StateFailed.
    #expect(await store.load() == VibeCheckConfig.default)
}

@Test func countsAreKeyedByDayAndPersist() async throws {
    let dir = try tempDir()
    let store = try CountsStore(directory: dir)
    #expect(try await store.increment(.nailBiting, on: "2026-08-14") == 1)
    #expect(try await store.increment(.nailBiting, on: "2026-08-14") == 2)
    #expect(try await store.increment(.nailBiting, on: "2026-08-15") == 1)
    #expect(try await store.increment(.nosePicking, on: "2026-08-14") == 1)

    let reloaded = try CountsStore(directory: dir)
    #expect(await reloaded.count(.nailBiting, on: "2026-08-14") == 2)
}

@Test func ordinalFollowsEnglishRules() {
    #expect(Ordinal.format(1) == "1st")
    #expect(Ordinal.format(2) == "2nd")
    #expect(Ordinal.format(3) == "3rd")
    #expect(Ordinal.format(4) == "4th")
    #expect(Ordinal.format(11) == "11th")
    #expect(Ordinal.format(12) == "12th")
    #expect(Ordinal.format(13) == "13th")
    #expect(Ordinal.format(21) == "21st")
    #expect(Ordinal.format(22) == "22nd")
    #expect(Ordinal.format(23) == "23rd")
    #expect(Ordinal.format(101) == "101st")
    #expect(Ordinal.format(111) == "111th")
    #expect(Ordinal.format(112) == "112th")
}
