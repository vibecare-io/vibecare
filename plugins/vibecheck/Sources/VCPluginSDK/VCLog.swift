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
    fputs("vibecheck: \(message)\n", stderr)
}
