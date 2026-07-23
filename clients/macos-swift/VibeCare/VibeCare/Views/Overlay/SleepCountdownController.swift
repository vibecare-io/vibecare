import Foundation

@MainActor
final class SleepCountdownController: ObservableObject {
    @Published private(set) var remaining: Int
    let cancelable: Bool

    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private var finished = false   // true once completed or canceled

    init(seconds: Int, cancelable: Bool,
         onComplete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.remaining = max(0, seconds)
        self.cancelable = cancelable
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    func tick() {
        guard !finished else { return }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 {
            finished = true
            onComplete()
        }
    }

    func cancel() {
        guard !finished, cancelable else { return }
        finished = true
        onCancel()
    }
}
