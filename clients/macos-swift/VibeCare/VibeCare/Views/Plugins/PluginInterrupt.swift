import AppKit
import AudioToolbox
import SwiftUI
import VibeNotify

/// Fires the immediate sound + screen flash a `"warn"` plugin alert requests
/// (ruling R1). Ported from the original in-client VibeCheck's
/// `Services/Detection/InterruptPlayer.swift` (the beep) and
/// `ViewModels/VibeCheckViewModel.swift`'s `flash` (the 250 ms overlay),
/// both deleted along with the rest of VibeCheck's in-client detection code
/// in a later task — this is where their behaviour lives now.
///
/// Two properties that matter, both inherited from the original and
/// deliberately preserved:
///
/// - **Bypasses `NotificationPolicy`.** The original's alert priority was
///   `.critical` *specifically because* the beep and flash already fired
///   unconditionally; the plugin's `level: "warn"` alert does not carry that
///   priority, so this call site checks nothing from `NotificationPolicy` at
///   all. The user's precise off switch is turning detection off, not the
///   global notification mute — see `PluginInterruptPolicy`.
/// - **Independent of the alert's own presentation.** This is called
///   unconditionally from `PluginShellService.deliver(_:)` before the alert
///   is routed to a renderer, so a failed icon fetch or a suppressed banner
///   never costs the user the interrupt.
///
/// Neither half can block the other or the alert presentation (both return
/// immediately; the flash's lifetime runs on its own timer), and neither can
/// crash the app: `AudioServicesPlaySystemSound` has no error path, and the
/// flash simply no-ops with no screen attached.
@MainActor
enum PluginInterrupt {
    /// Total on-screen lifetime of the flash overlay window: the 250 ms the
    /// original held `flash == true`, plus the 200 ms easeOut fade-out the
    /// original's `.animation(.easeOut(duration: 0.2), value: flash)`
    /// applied to the false transition. The window is torn down only once
    /// its content has fully faded, matching what the original's always-on
    /// overlay looked like frame by frame.
    private static let holdDuration: TimeInterval = 0.25
    private static let fadeDuration: TimeInterval = 0.2

    private static var activeFlashID: UUID?

    /// Entry point for a delivered plugin alert. Decides via
    /// `PluginInterruptPolicy` and, if it fires, plays the sound and shows
    /// the flash — neither waits on the other.
    static func fire(alertLevel: String) {
        guard PluginInterruptPolicy.shouldInterrupt(level: alertLevel) else { return }
        playSound()
        flash()
    }

    // MARK: - Sound

    /// `AudioServicesPlaySystemSound` over `NSSound.beep()`: it needs only
    /// AudioToolbox (not the whole `NSSound` object), is fire-and-forget
    /// (the system mixer plays it asynchronously; the call itself returns
    /// immediately, so it cannot block alert delivery), and
    /// `kSystemSoundID_UserPreferredAlert` is the documented request for
    /// "the same alert sound `NSSound.beep()` plays" — i.e. this is not a
    /// behaviour change, only a lighter-weight call for the same sound.
    /// `NSSound.beep()` would also be fine here (this is a client, not a
    /// daemon), it's just a heavier tool for the same job.
    private static func playSound() {
        AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
    }

    // MARK: - Flash

    /// Full-screen translucent red flash, matching `VibeCheckScreen`'s
    /// `flashOverlay` exactly: `Color.red.opacity(0.35)` while active, eased
    /// out over 0.2s. Skipped under Reduce Motion (the sound still fires);
    /// skipped with no screen attached, rather than crashing.
    private static func flash() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard NSScreen.main != nil else { return }

        // Only one flash on screen at a time: a detection during another
        // detection's cooldown fade should not stack two windows.
        if let previous = activeFlashID {
            OverlayWindowManager.shared.dismiss(id: previous, animated: false)
        }

        let id = UUID()
        activeFlashID = id

        // `animatePresentation: false` — the window itself must appear at
        // full alpha instantly; the fade is the Rectangle's own opacity
        // animation inside `PluginFlashOverlayView`, not the window's.
        let configuration = OverlayWindowManager.Configuration(
            presentationMode: .fullScreen,
            windowLevel: .floating,
            backgroundColor: .clear,
            isTransparent: true,
            ignoresMouseEvents: true,
            isMoveable: false,
            alwaysOnTop: true,
            screenBlur: false,
            dismissOnScreenTap: false,
            animatePresentation: false
        )
        OverlayWindowManager.shared.show(id: id, configuration: configuration) {
            PluginFlashOverlayView(holdDuration: holdDuration, fadeDuration: fadeDuration)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration + fadeDuration) {
            OverlayWindowManager.shared.dismiss(id: id, animated: false)
            if activeFlashID == id { activeFlashID = nil }
        }
    }
}

/// The flash itself: a hit-testing-transparent red rectangle that ramps up
/// to 0.35 opacity and back down to 0, both legs eased out over
/// `fadeDuration`, spending `holdDuration` at (or animating toward) full
/// opacity before reverting — the same shape as the original's
/// `Rectangle().fill(Color.red.opacity(flash ? 0.35 : 0))
/// .animation(.easeOut(duration: 0.2), value: flash)`.
private struct PluginFlashOverlayView: View {
    let holdDuration: TimeInterval
    let fadeDuration: TimeInterval

    @State private var opacity: Double = 0

    var body: some View {
        Rectangle()
            .fill(Color.red.opacity(opacity))
            .animation(.easeOut(duration: fadeDuration), value: opacity)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onAppear {
                opacity = 0.35
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
                    opacity = 0
                }
            }
    }
}
