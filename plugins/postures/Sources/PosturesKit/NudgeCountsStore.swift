import Foundation

/// Date-keyed nudge counts, durable across relaunches, in
/// `$VIBECARE_DATA_DIR/counts.json`.
///
/// Date-keyed rather than a running total because "3rd nudge today" is the
/// only count the alert copy and the UI ever state, and a total that never
/// resets would make both meaningless by the end of the week. Keeping the
/// older days rather than overwriting one bucket costs a few bytes and leaves
/// the door open for a trend view later without a migration.
///
/// There is no `UserDefaults` anywhere near this: a plugin binary has no
/// bundle identifier, so `UserDefaults.standard` would write into whichever
/// process happened to spawn it.
public actor NudgeCountsStore {
    private let url: URL
    private var counts: [String: Int]

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("counts.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.counts = decoded
        } else {
            // Missing or corrupt: start from zero rather than refuse to
            // launch. Same rule, same reason, as `ConfigStore`.
            self.counts = [:]
        }
    }

    /// "yyyy-MM-dd" in local time, matching how a user thinks about "today".
    /// `en_US_POSIX` so the format string means what it says regardless of
    /// the user's locale.
    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    @discardableResult
    public func increment(on day: String) throws -> Int {
        let next = (counts[day] ?? 0) + 1
        counts[day] = next
        try flush()
        return next
    }

    public func count(on day: String) -> Int { counts[day] ?? 0 }

    private func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(counts)
        // Atomic for the same reason as `ConfigStore`: a partial write that
        // fails to parse on next launch would silently reset every count.
        try data.write(to: url, options: .atomic)
    }
}
