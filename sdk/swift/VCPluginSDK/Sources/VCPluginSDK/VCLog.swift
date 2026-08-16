import Foundation

/// The one sanctioned way to write a diagnostic line in this SDK.
///
/// It exists to keep `FileHandle.standardError.write(_:)` out of the package.
/// That overload is the non-throwing one: it raises an **uncatchable**
/// `NSException` — an abort, not a Swift error, so no `try?` and no `catch`
/// can contain it — when the descriptor is closed or the pipe has no reader.
/// Core closes the plugin's stderr pipe during its own shutdown, so a single
/// diagnostic emitted after that point kills the process, and
/// `supervisor.go` charges an unrequested exit as a failed start
/// (`maxFailedStarts` = 5, then `StateFailed` until a manual dashboard
/// restart).
///
/// That makes it exactly wrong for the two places this SDK logs from: the
/// reconnect loop, which runs while core is going away, and `VCHTTPServer`'s
/// request error handler, which runs only when something has already gone
/// wrong. This package promises that nothing in it terminates the process;
/// it must not hold an abort path to keep that promise.
///
/// `fputs` returns `EOF` and moves on.
func vcLog(_ message: String) {
    fputs("\(vcLogPrefix): \(message)\n", stderr)
}

/// The plugin's own id, so a line the SDK emits from inside the `postures`
/// process says `postures:` and not the id of whichever plugin the SDK was
/// extracted from.
///
/// This used to be the literal `"vibecheck"`, which was harmless while
/// vibecheck was the only Swift plugin and actively misleading the moment
/// there were four — core captures every plugin's stderr into one log, so
/// `vibecheck: sdk: register session ended` coming out of `blink-jump` sends
/// whoever is debugging to the wrong process.
///
/// Read once from the spawn environment rather than threaded through
/// `connect()`: `vcLog` is called from `VCHTTPServer` and the reconnect loop,
/// neither of which has a `VCHost` to ask, and the variable is set by
/// `supervisor.go` before the process starts and never changes. `"plugin"` is
/// the fallback for a binary run by hand outside a spawn — a case where there
/// is no id to be right about.
let vcLogPrefix: String = ProcessInfo.processInfo.environment["VIBECARE_PLUGIN_ID"]
    .flatMap { $0.isEmpty ? nil : $0 } ?? "plugin"
