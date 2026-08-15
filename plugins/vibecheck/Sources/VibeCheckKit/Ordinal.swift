import Foundation

/// Formats the "Nth nudge today" copy. Moved from the client's
/// VibeNotifyConfiguration.ordinal, which is deleted in Task 18.
public enum Ordinal {
    public static func format(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1:  return "\(n)st"
        case 2:  return "\(n)nd"
        case 3:  return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
