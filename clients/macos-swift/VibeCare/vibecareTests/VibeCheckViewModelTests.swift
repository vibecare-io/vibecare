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

private final class FakePreference: DetectionPreferenceStoring {
    var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
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

/// `resumeIfEnabled` must not touch the camera when the persisted preference
/// is off — no camera hardware is exercised by this path.
@MainActor
@Test func resumeIfEnabledIsNoopWhenPreferenceDisabled() async {
    let fake = FakePreference(enabled: false)
    let vm = VibeCheckViewModel(interrupt: NoopInterrupt(), notifier: SpyNotifier(), preference: fake)

    await vm.resumeIfEnabled()

    #expect(vm.isDetectionEnabled == false)
    #expect(vm.isRunning == false)
}

/// `setDetection(false)` must resolve `isDetectionEnabled` to false and
/// persist that back to the preference store. The off-path never awaits into
/// the camera, so it's safe to exercise without hardware.
@MainActor
@Test func setDetectionFalsePersistsDisabled() async {
    let fake = FakePreference(enabled: true)
    let vm = VibeCheckViewModel(interrupt: NoopInterrupt(), notifier: SpyNotifier(), preference: fake)

    await vm.setDetection(false)

    #expect(vm.isDetectionEnabled == false)
    #expect(fake.enabled == false)
}
