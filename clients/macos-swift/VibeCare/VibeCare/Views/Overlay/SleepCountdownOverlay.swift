import AppKit
import SwiftUI
import Logging

@MainActor
final class SleepCountdownOverlay {
    static let shared = SleepCountdownOverlay()
    private let logger = Logger(label: "com.vibecare.sleep-overlay")

    private var window: NSWindow?
    private var controller: SleepCountdownController?
    private var timer: Timer?

    /// Show the countdown. `onComplete` runs when it reaches zero (not on cancel).
    func present(seconds: Int, cancelable: Bool, message: String?,
                 onComplete: @escaping () -> Void) {
        guard window == nil else {
            logger.warning("Countdown already showing; ignoring duplicate present")
            return
        }
        let controller = SleepCountdownController(
            seconds: seconds, cancelable: cancelable,
            onComplete: { [weak self] in self?.dismiss(); onComplete() },
            onCancel:   { [weak self] in self?.dismiss() })
        self.controller = controller

        let screenFrame = NSScreen.main?.frame ?? .zero
        let window = NSWindow(contentRect: screenFrame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: SleepCountdownView(controller: controller, message: message,
                                         onCancel: { controller.cancel() }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in controller.tick() }
        }
    }

    private func dismiss() {
        timer?.invalidate(); timer = nil
        window?.contentView = nil   // drop the SwiftUI hierarchy / hosting view promptly
        window?.close()             // remove from AppKit's window list (orderOut only hides)
        window = nil
        controller = nil
    }
}

private struct SleepCountdownView: View {
    @ObservedObject var controller: SleepCountdownController
    let message: String?
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("🌙 \(message ?? "Time to wind down")")
                    .font(.system(size: 34, weight: .semibold))
                Text("Sleeping in \(controller.remaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if controller.cancelable {
                    Text("press Esc to stay awake")
                        .font(.title3).foregroundStyle(.secondary)
                    Button("Stay awake", action: onCancel)
                        .keyboardShortcut(.cancelAction)   // Esc
                        .controlSize(.large)
                }
            }
            .foregroundStyle(.white)
        }
    }
}
