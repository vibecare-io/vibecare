import Foundation

/// The words on the alert. Split out from `PostureMonitor` because it is pure
/// and worth asserting on its own — the monitor around it needs a host, a
/// clock and three stores before it can say anything.
public enum NudgeCopy {
    public static let title = "Sit up"

    /// "1st", "2nd", "3rd", "11th" — English ordinals, including the teens
    /// exception that a naive `% 10` gets wrong.
    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1:  return "\(n)st"
        case 2:  return "\(n)nd"
        case 3:  return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// Coarse and human: "2 minutes", "1 minute", "45 seconds". Rounded down,
    /// so the alert never claims more time than actually elapsed.
    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        if whole < 90 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        let minutes = whole / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// Names what was actually measured rather than always saying
    /// "slouching". A user whose shoulders are level and whose head is
    /// craned forward is told about their head; being told about their
    /// shoulders instead would read as a broken detector and it would be
    /// right.
    public static func body(faults: PostureFaults, sustained: TimeInterval, count: Int) -> String {
        let howLong = duration(sustained)
        let what: String
        switch (faults.contains(.unevenShoulders), faults.contains(.forwardHead)) {
        case (true, true):
            what = "You've been slouching for \(howLong)"
        case (true, false):
            what = "Your shoulders have been uneven for \(howLong)"
        case (false, true):
            what = "Your head has been forward of your shoulders for \(howLong)"
        case (false, false):
            // Unreachable through `PostureScore`, which only returns `.poor`
            // with at least one fault set. Stated rather than crashed on:
            // nothing in a plugin terminates the process, least of all the
            // string formatter.
            what = "Your posture has been off for \(howLong)"
        }
        return "\(what) — \(ordinal(count)) nudge today"
    }
}
