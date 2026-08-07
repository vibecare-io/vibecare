import Testing
import Foundation
@testable import vibecare

@MainActor
@Test func preferencesForSeedsFromDefaultAndReturnsStableInstance() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let store = DetectionAlertPreferencesStore(defaults: defaults)
    let first = store.preferences(for: .nailBiting)
    // seeded from .default
    #expect(first.position == NotificationPreferences.default.position)
    #expect(first.width == NotificationPreferences.default.width)
    // stable instance on repeat access (so the editor binds one object)
    #expect(store.preferences(for: .nailBiting) === first)
}

@MainActor
@Test func persistedEditsAreReadBackByASecondStore() {
    let name = "test.vibecheck.alertprefs.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }

    let writer = DetectionAlertPreferencesStore(defaults: defaults)
    let prefs = writer.preferences(for: .nosePicking)
    prefs.position = .bottomRight
    prefs.title = "Hands away"
    writer.persist()

    let reader = DetectionAlertPreferencesStore(defaults: defaults)
    let read = reader.preferences(for: .nosePicking)
    #expect(read.position == .bottomRight)
    #expect(read.title == "Hands away")
}

@MainActor
@Test func encodedSnapshotDecodesToEqualMap() throws {
    let store = DetectionAlertPreferencesStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    _ = store.preferences(for: .hairPulling)   // materialize one entry
    let decoded = try JSONDecoder().decode([String: NotificationPreferences].self, from: store.encodedSnapshot)
    #expect(decoded == store.byBehavior)
}
