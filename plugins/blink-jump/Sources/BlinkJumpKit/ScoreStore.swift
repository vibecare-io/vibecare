import Foundation

/// The scoreboard, durable across relaunches.
///
/// The game itself runs in the browser — canvas and `requestAnimationFrame`
/// own the physics — so the page is the only thing that knows a run ended and
/// what it was worth. It reports the final score here; this is where it stops
/// being a number in a tab that a reload throws away.
public struct BlinkJumpScores: Codable, Sendable, Equatable {
    public var highScore: Int
    public var gamesPlayed: Int
    public var totalJumps: Int
    public var lastScore: Int
    public var lastPlayed: Date?

    public init(
        highScore: Int = 0,
        gamesPlayed: Int = 0,
        totalJumps: Int = 0,
        lastScore: Int = 0,
        lastPlayed: Date? = nil
    ) {
        self.highScore = highScore
        self.gamesPlayed = gamesPlayed
        self.totalJumps = totalJumps
        self.lastScore = lastScore
        self.lastPlayed = lastPlayed
    }

    public static let empty = BlinkJumpScores()
}

/// `scores.json` in `VIBECARE_DATA_DIR`, same discipline as `ConfigStore`:
/// missing or corrupt reads as empty, writes are atomic.
public actor ScoreStore {
    private let url: URL
    private var cached: BlinkJumpScores

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("scores.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.blinkJump().decode(BlinkJumpScores.self, from: data) {
            self.cached = decoded
        } else {
            self.cached = .empty
        }
    }

    public func load() -> BlinkJumpScores { cached }

    /// Records a finished run and returns the updated board.
    ///
    /// Negative and absurd values are clamped rather than rejected: this is
    /// reachable from a `POST` a player could hand-craft, and the only thing
    /// at stake is their own scoreboard, so a 400 buys nothing that a clamp
    /// does not. The high score only ever moves up.
    @discardableResult
    public func record(score: Int, jumps: Int, at now: Date = Date()) throws -> BlinkJumpScores {
        var next = cached
        let score = min(9_999_999, max(0, score))
        let jumps = min(9_999_999, max(0, jumps))
        next.lastScore = score
        next.highScore = max(next.highScore, score)
        next.gamesPlayed += 1
        next.totalJumps += jumps
        next.lastPlayed = now

        let encoder = JSONEncoder.blinkJump()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: url, options: .atomic)
        // Only after the write lands: a cache holding a score that failed to
        // persist would report a high score the next launch does not have.
        cached = next
        return next
    }
}
