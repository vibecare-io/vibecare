import Foundation

/// Countdown options for one-shot timer templates
/// Simplified format: array of minutes + default value
struct CountdownOptions: Equatable, Hashable {
    let durations: [Int]      // Available durations in minutes
    let defaultMinutes: Int   // Default selection

    // MARK: - Standard Fallback

    /// Standard preset used when template has no countdown options
    static let standard = CountdownOptions(
        durations: [5, 10, 30, 60, 120],
        defaultMinutes: 30
    )

    // MARK: - Label Generation

    /// Generate human-readable label for a duration in minutes
    /// Examples: 5 → "5 mins", 60 → "1 hour", 90 → "1.5 hours"
    static func label(for minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) min\(minutes == 1 ? "" : "s")"
        } else {
            let hours = Double(minutes) / 60.0
            if hours.truncatingRemainder(dividingBy: 1) == 0 {
                let intHours = Int(hours)
                return "\(intHours) hour\(intHours == 1 ? "" : "s")"
            } else {
                return String(format: "%.1f hours", hours)
            }
        }
    }

    /// Get labels for all durations
    var labels: [String] {
        durations.map { CountdownOptions.label(for: $0) }
    }

    /// Get (minutes, label) tuples for slider
    var presets: [(minutes: Int, label: String)] {
        durations.map { ($0, CountdownOptions.label(for: $0)) }
    }

    /// Index of the default duration in the array
    var defaultIndex: Int {
        durations.firstIndex(of: defaultMinutes) ?? 0
    }
}
