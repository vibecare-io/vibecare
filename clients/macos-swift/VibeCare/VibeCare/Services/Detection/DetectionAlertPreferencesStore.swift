import Foundation
import SwiftUI

/// App-wide, persisted store for per-behavior VibeCheck detection-alert
/// preferences. Reuses `NotificationPreferences` (the same model schedule
/// notifications use). The Advanced settings UI binds to `.shared`, and
/// `showBFRBAlert` reads `preferences(for:)` at fire time.
///
/// `NotificationPreferences` is a reference type, so field edits mutate in place
/// and won't trigger value-based change detection. Auto-save is driven by the
/// settings view observing `encodedSnapshot` (whose read touches every field, so
/// Observation re-fires on any edit) and calling `persist()`.
@MainActor
final class DetectionAlertPreferencesStore: ObservableObject {
    static let shared = DetectionAlertPreferencesStore()

    @Published var byBehavior: [String: NotificationPreferences]

    private let defaults: UserDefaults
    private let key = "vibecheck.alert.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seededMap: [String: NotificationPreferences]
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: NotificationPreferences].self, from: data) {
            seededMap = decoded
        } else {
            seededMap = [:]
        }
        // Ensure every known behavior has an entry so `preferences(for:)` can be a
        // pure, non-mutating lookup (mutating @Published state from a getter reached
        // during SwiftUI view-body evaluation is undefined behavior).
        for b in BFRBBehavior.allCases where seededMap[b.rawValue] == nil {
            seededMap[b.rawValue] = NotificationPreferences.default.copy()
        }
        self.byBehavior = seededMap
    }

    /// Pure lookup for the prefs for `b`. `init` pre-seeds every `BFRBBehavior` case,
    /// so this normally finds an existing, stable instance; the `??` fallback is
    /// defensive only and does not mutate `byBehavior`.
    func preferences(for b: BFRBBehavior) -> NotificationPreferences {
        byBehavior[b.rawValue] ?? NotificationPreferences.default.copy()
    }

    /// Encoded snapshot of the whole map. Reading it touches every field of every
    /// `NotificationPreferences`, so a SwiftUI `onChange(of:)` on this value
    /// re-fires on ANY field edit (Observation tracks the reads) — that is how the
    /// settings view triggers reliable auto-save.
    var encodedSnapshot: Data { (try? JSONEncoder().encode(byBehavior)) ?? Data() }

    func persist() {
        guard let data = try? JSONEncoder().encode(byBehavior) else { return }
        defaults.set(data, forKey: key)
    }
}
