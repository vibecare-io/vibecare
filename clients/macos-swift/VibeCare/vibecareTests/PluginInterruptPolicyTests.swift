import Testing
import Foundation
// Two build systems, two module names for the app — see the long comment in
// PluginRosterTests.swift. Do not "simplify" this to one import.
#if SWIFT_PACKAGE
@testable import VibeCare
#else
@testable import vibecare
#endif

// Ruling R1: the original client's audible interrupt + screen flash fired on
// every confirmed BFRB detection, unconditionally, independent of the
// notification and of the user's global mute toggle. The Swift plugin port
// dropped both. This restores them on the client's plugin-alert path, keyed
// on `level` alone since `"info"`/`"warn"` is the whole vocabulary.
//
// `PluginInterruptPolicy.shouldInterrupt` is the one part of that restoration
// that can be tested without a screen or an audio session — see
// `PluginInterrupt` for the sound/flash themselves, which cannot be.

@Test func warnAlertsRequestTheInterrupt() {
    #expect(PluginInterruptPolicy.shouldInterrupt(level: "warn"))
}

@Test func infoAlertsDoNotRequestTheInterrupt() {
    #expect(!PluginInterruptPolicy.shouldInterrupt(level: "info"))
}

// Not "todo" or "vibecheck" — the vocabulary is the level string itself, not
// which plugin sent it. An unrecognised level is treated like "info": no
// plugin should get an unmutable interrupt by accident because it sent a
// typo'd level.
@Test func unrecognisedLevelsDoNotRequestTheInterrupt() {
    #expect(!PluginInterruptPolicy.shouldInterrupt(level: "urgent"))
    #expect(!PluginInterruptPolicy.shouldInterrupt(level: ""))
}

// The requirement this guards against: someone later threading
// `NotificationPolicy.shared.enabled` into `shouldInterrupt` (e.g. "while
// we're in here, may as well respect the mute toggle") would silently
// reintroduce the exact regression ruling R1 restores. `shouldInterrupt`
// takes no `NotificationPolicy` input at all, so this flips the toggle and
// checks the decision doesn't move — a real coupling would fail this.
@MainActor
@Test func muteToggleDoesNotSuppressTheDecision() {
    let policy = NotificationPolicy.shared
    let original = policy.enabled
    defer { policy.enabled = original }

    policy.enabled = false
    #expect(PluginInterruptPolicy.shouldInterrupt(level: "warn"))

    policy.enabled = true
    #expect(PluginInterruptPolicy.shouldInterrupt(level: "warn"))
}
