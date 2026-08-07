import Testing
import Foundation
import CoreGraphics
@testable import vibecare

@Test func appearanceDefaultMatchesLegacyHardcodedValues() {
    let d = DetectionAlertAppearance.default
    #expect(d.position == .center)
    #expect(d.width == 480)
    #expect(d.height == 300)
    #expect(d.moveable == true)
    #expect(d.screenBlurEnabled == true)
    #expect(d.screenBlurIntensity == .medium)
    #expect(d.autoDismissAfter == 6.0)
}

@Test func codableRoundTripPreservesCustomization() throws {
    var prefs = DetectionAlertPreferences()
    prefs.shared.position = .topRight
    prefs.perBehavior["nailBiting"] = DetectionAlertBehaviorPrefs(
        titleOverride: "Hands", messageOverride: "Down", iconSVGPath: "/tmp/x.svg",
        iconSVGWidth: 40, iconSVGHeight: 40, overridesAppearance: true,
        appearance: .prominent)
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(DetectionAlertPreferences.self, from: data)
    #expect(decoded == prefs)
}

@Test func effectiveAppearanceUsesSharedUnlessOverridden() {
    var prefs = DetectionAlertPreferences()
    prefs.shared.width = 400
    #expect(prefs.effectiveAppearance(for: .nosePicking).width == 400)

    var bp = DetectionAlertBehaviorPrefs()
    bp.overridesAppearance = true
    bp.appearance = .prominent
    prefs.perBehavior["nosePicking"] = bp
    #expect(prefs.effectiveAppearance(for: .nosePicking) == .prominent)
    // other behaviors still use shared
    #expect(prefs.effectiveAppearance(for: .hairPulling).width == 400)
}

@Test func effectiveTitleMessageFallBackToBehaviorDefaults() {
    var prefs = DetectionAlertPreferences()
    #expect(prefs.effectiveTitle(for: .hairPulling) == BFRBBehavior.hairPulling.label)
    #expect(prefs.effectiveMessage(for: .hairPulling) == BFRBBehavior.hairPulling.nudge)

    prefs.perBehavior["hairPulling"] = DetectionAlertBehaviorPrefs(
        titleOverride: "  ", messageOverride: "Gently now")   // whitespace title ignored
    #expect(prefs.effectiveTitle(for: .hairPulling) == BFRBBehavior.hairPulling.label)
    #expect(prefs.effectiveMessage(for: .hairPulling) == "Gently now")
}

@Test func effectiveIconIsSymbolByDefaultAndSvgWhenSet() {
    var prefs = DetectionAlertPreferences()
    #expect(prefs.effectiveIcon(for: .nailBiting) == .symbol(BFRBBehavior.nailBiting.alertIcon))

    prefs.perBehavior["nailBiting"] = DetectionAlertBehaviorPrefs(
        iconSVGPath: "/tmp/i.svg", iconSVGWidth: 50, iconSVGHeight: 60)
    #expect(prefs.effectiveIcon(for: .nailBiting) == .svg(path: "/tmp/i.svg", size: CGSize(width: 50, height: 60)))
}

@MainActor
@Test func storeDefaultsToDefaultPreferencesWhenUnset() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let store = DetectionAlertPreferencesStore(defaults: defaults)
    #expect(store.preferences == DetectionAlertPreferences())
}

@MainActor
@Test func storePersistsEditsAndSecondStoreReadsThemBack() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let writer = DetectionAlertPreferencesStore(defaults: defaults)
    writer.preferences.shared.position = .bottomRight
    writer.setBehavior(.nailBiting, DetectionAlertBehaviorPrefs(messageOverride: "Down"))

    let reader = DetectionAlertPreferencesStore(defaults: defaults)
    #expect(reader.preferences.shared.position == .bottomRight)
    #expect(reader.behavior(.nailBiting).messageOverride == "Down")
}
