import Testing
import Foundation
@testable import vibecare

@Suite struct DetectionPreferenceTests {

    /// Makes an isolated UserDefaults suite so `.standard` is never polluted.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "test.vibecheck.detection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test func defaultsToFalseWhenUnset() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let pref = DetectionPreference(defaults: defaults)

        #expect(pref.enabled == false)
    }

    @Test func persistsTrueThenFalse() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        var pref = DetectionPreference(defaults: defaults)
        pref.enabled = true
        #expect(pref.enabled == true)

        pref.enabled = false
        #expect(pref.enabled == false)
    }

    @Test func secondInstanceOverSameSuiteSeesPersistedValue() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        var writer = DetectionPreference(defaults: defaults)
        writer.enabled = true

        let reader = DetectionPreference(defaults: defaults)
        #expect(reader.enabled == true)
    }
}
