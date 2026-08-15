import Foundation

/// Date-keyed nudge counts, durable across relaunches. Today `sessionCounts`
/// in the client is in-memory and resets on restart, which makes "Nth nudge
/// today" copy wrong after any restart — this is what makes it honest.
///
/// Stored as `day -> behavior -> count`, day-first so a future "reset today"
/// or retention sweep can operate on a single top-level key without touching
/// the rest of the file.
public actor CountsStore {
    private let url: URL
    private var counts: [String: [String: Int]]

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("counts.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            self.counts = decoded
        } else {
            // Missing or corrupt: same rule as ConfigStore — never throw out
            // of a plugin's init over a file that hasn't been written yet or
            // got truncated. Start from zero rather than refuse to launch.
            self.counts = [:]
        }
    }

    /// "yyyy-MM-dd" in local time, matching how a user thinks about "today".
    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    @discardableResult
    public func increment(_ behavior: BFRBBehavior, on day: String) throws -> Int {
        var dayCounts = counts[day] ?? [:]
        let next = (dayCounts[behavior.rawValue] ?? 0) + 1
        dayCounts[behavior.rawValue] = next
        counts[day] = dayCounts
        try flush()
        return next
    }

    public func count(_ behavior: BFRBBehavior, on day: String) -> Int {
        counts[day]?[behavior.rawValue] ?? 0
    }

    private func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(counts)
        // Atomic for the same reason as ConfigStore: a partial write that
        // fails to parse on next launch would silently reset every count.
        try data.write(to: url, options: .atomic)
    }
}
