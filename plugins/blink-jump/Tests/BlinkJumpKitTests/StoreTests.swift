import Foundation
import Testing
@testable import BlinkJumpKit

/// A throwaway stand-in for `VIBECARE_DATA_DIR`, which core creates 0700
/// before spawn.
private func makeDataDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blink-jump-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeDataDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Scores

@Test func aHighScoreSurvivesTheProcessThatSetIt() async throws {
    let dir = try makeDataDir()
    defer { removeDataDir(dir) }

    let store = ScoreStore(directory: dir)
    _ = try await store.record(score: 120, jumps: 9)
    _ = try await store.record(score: 340, jumps: 22)
    _ = try await store.record(score: 90, jumps: 4)

    // Read straight off disk rather than through the actor that wrote it — a
    // cache that agrees with itself proves nothing about what was persisted.
    let raw = try Data(contentsOf: dir.appendingPathComponent("scores.json"))
    let onDisk = try JSONDecoder.blinkJump().decode(BlinkJumpScores.self, from: raw)

    #expect(onDisk.highScore == 340)
    #expect(onDisk.lastScore == 90, "the last run is the last run even when it is not the best")
    #expect(onDisk.gamesPlayed == 3)
    #expect(onDisk.totalJumps == 35)
    #expect(onDisk.lastPlayed != nil)

    // And a fresh process picks it up, which is the thing the player notices.
    let reopened = await ScoreStore(directory: dir).load()
    #expect(reopened == onDisk)
}

@Test func aMissingOrCorruptScoreFileStartsFromZeroRatherThanFailing() async throws {
    let dir = try makeDataDir()
    defer { removeDataDir(dir) }

    #expect(await ScoreStore(directory: dir).load() == .empty)

    // Refusing to construct here would be an unrequested exit, and five of
    // those park the plugin in StateFailed until a manual restart.
    try Data("{ this is not json".utf8).write(to: dir.appendingPathComponent("scores.json"))
    #expect(await ScoreStore(directory: dir).load() == .empty)
}

@Test func absurdScoresAreClampedRatherThanRejected() async throws {
    let dir = try makeDataDir()
    defer { removeDataDir(dir) }

    let store = ScoreStore(directory: dir)
    let board = try await store.record(score: -5, jumps: -1)
    #expect(board.highScore == 0)
    #expect(board.totalJumps == 0)
}

// MARK: - Config

@Test func calibrationSurvivesARestart() async throws {
    let dir = try makeDataDir()
    defer { removeDataDir(dir) }

    let saved = try await ConfigStore(directory: dir).save(BlinkJumpConfig(
        thresholds: BlinkThresholds(close: 0.16, hysteresis: 0.04),
        fps: 30,
        baselineOpenEar: 0.28,
        calibratedAt: Date(timeIntervalSince1970: 1_770_000_000)
    ))
    #expect(saved.thresholds.close == 0.16)

    let reopened = await ConfigStore(directory: dir).load()
    #expect(reopened.thresholds.close == 0.16)
    #expect(reopened.thresholds.hysteresis == 0.04)
    #expect(reopened.baselineOpenEar == 0.28)
    // ISO-8601 on both sides, or the date round-trips silently wrong.
    #expect(reopened.calibratedAt == Date(timeIntervalSince1970: 1_770_000_000))
}

@Test func saveReturnsWhatWasWrittenNotWhatWasAskedFor() async throws {
    let dir = try makeDataDir()
    defer { removeDataDir(dir) }

    let store = ConfigStore(directory: dir)
    // fps 0 means "the provider's default" on the wire — silently swapping the
    // player's setting for someone else's default is worse than clamping.
    let saved = try await store.save(BlinkJumpConfig(thresholds: BlinkThresholds(close: 9), fps: 0))

    #expect(saved.fps == 5)
    #expect(saved.thresholds.close <= 0.45)
    #expect(await store.load() == saved, "the cache must never disagree with the file")

    let raw = try Data(contentsOf: dir.appendingPathComponent("config.json"))
    let onDisk = try JSONDecoder.blinkJump().decode(BlinkJumpConfig.self, from: raw)
    #expect(onDisk == saved)
}
