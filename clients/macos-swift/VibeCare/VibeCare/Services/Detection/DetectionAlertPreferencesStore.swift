import Foundation
import SwiftUI

/// App-wide, persisted store for the VibeCheck detection-alert preferences.
/// JSON-encoded into UserDefaults; the Advanced settings UI binds to `.shared`
/// and `showBFRBAlert` reads `.shared.preferences` at fire time.
@MainActor
final class DetectionAlertPreferencesStore: ObservableObject {
    static let shared = DetectionAlertPreferencesStore()

    @Published var preferences: DetectionAlertPreferences {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key = "vibecheck.alert.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(DetectionAlertPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = DetectionAlertPreferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }

    /// The stored prefs for `b`, or a fresh default entry if none yet.
    func behavior(_ b: BFRBBehavior) -> DetectionAlertBehaviorPrefs {
        preferences.perBehavior[b.rawValue] ?? DetectionAlertBehaviorPrefs()
    }

    /// Upsert `b`'s prefs (reassigns `perBehavior` to trigger `didSet`/persist).
    func setBehavior(_ b: BFRBBehavior, _ prefs: DetectionAlertBehaviorPrefs) {
        preferences.perBehavior[b.rawValue] = prefs
    }
}
