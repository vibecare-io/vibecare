import Testing
@testable import vibecare

@MainActor
private final class SpyNotifier: DetectionNotifying {
    struct Call: Equatable { let behavior: BFRBBehavior; let count: Int }
    var calls: [Call] = []
    func notify(behavior: BFRBBehavior, count: Int) {
        calls.append(Call(behavior: behavior, count: count))
    }
}

private struct NoopInterrupt: InterruptPlaying {
    func play(_ behavior: BFRBBehavior) {}
}

/// A confirmed detection must fire exactly one notification carrying the
/// detected behavior and its post-increment session count, so the alert shows
/// the right icon/message and the "Nth nudge today" streak stays accurate.
@MainActor
@Test func detectionNotifiesWithBehaviorAndIncrementingCount() {
    let spy = SpyNotifier()
    let vm = VibeCheckViewModel(interrupt: NoopInterrupt(), notifier: spy)

    vm.fire(BFRBEvent(behavior: .nailBiting, time: 0))
    vm.fire(BFRBEvent(behavior: .nailBiting, time: 1))
    vm.fire(BFRBEvent(behavior: .nosePicking, time: 2))

    #expect(spy.calls == [
        .init(behavior: .nailBiting, count: 1),
        .init(behavior: .nailBiting, count: 2),
        .init(behavior: .nosePicking, count: 1),
    ])
}
