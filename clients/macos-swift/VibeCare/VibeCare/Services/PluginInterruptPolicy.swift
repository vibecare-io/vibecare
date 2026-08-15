import Foundation

/// Decides whether a plugin alert should trigger the immediate, unmutable
/// sound + screen flash (see `PluginInterrupt`), independent of which
/// renderer the alert itself gets and independent of `NotificationPolicy`.
///
/// Ruling R1 (`.superpowers/sdd/2026-08-14-vibecheck-swift-plugin/`):
/// the original client fired `NSSound.beep()` and a 250 ms screen flash on
/// *every* confirmed BFRB detection, unconditionally — not gated on the
/// notification, and not gated on the user's global mute toggle. That
/// behaviour was silently dropped when detection moved into the
/// `vibecheck` plugin. This restores it on the client's plugin-alert path,
/// keyed on the one piece of vocabulary alerts already carry: `level`. Only
/// `"info"` and `"warn"` exist — `todo` sends info, `vibecheck` sends warn —
/// so no new field is needed to carry the distinction.
///
/// Deliberately a free function over a plain `String`, not a method on
/// `PluginAlert`: the whole point is that this decision needs no AppKit, no
/// screen, and no audio session to test.
enum PluginInterruptPolicy {
    static func shouldInterrupt(level: String) -> Bool {
        level == "warn"
    }
}
