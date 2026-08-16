import Foundation

/// The one sanctioned way to write a diagnostic line from this module. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — same rule as
/// `VCPluginSDK/VCLog.swift`: the `FileHandle` overload raises an
/// *uncatchable* `NSException` on a closed descriptor, and core closes the
/// plugin's stderr pipe during its own shutdown. `supervisor.go` charges the
/// resulting abort as a failed start, and five of those park the plugin in
/// `StateFailed`. `VCPluginSDK`'s own `vcLog` is internal to that module, so
/// `VisionKit` needs its own copy.
func visionLog(_ message: String) {
    fputs("vision: \(message)\n", stderr)
}

/// `Duration` -> plain seconds. Every throttle and TTL in this module measures
/// against `ContinuousClock` (monotonic) rather than `Date` (wall clock): a
/// backward NTP step would make a `Date`-based elapsed time negative, which
/// silently fails every `elapsed >= interval` gate until real time catches
/// back up — capture dead, no log line.
func visionSeconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
