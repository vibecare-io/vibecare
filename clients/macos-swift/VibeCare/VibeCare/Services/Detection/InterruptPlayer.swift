import AppKit

protocol InterruptPlaying { func play(_ behavior: BFRBBehavior) }

/// Plays a system alert sound. The overlay flash is driven by the view model
/// (a @Published Bool) so the SUT can be tested without AppKit if needed.
final class InterruptPlayer: InterruptPlaying {
    func play(_ behavior: BFRBBehavior) {
        NSSound.beep()
    }
}
