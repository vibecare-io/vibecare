import Foundation

/// Injectable persistence for the app-wide VibeCheck detection on/off flag.
/// Abstracted so `VibeCheckViewModel` can be tested against an in-memory
/// stand-in instead of `.standard` UserDefaults.
protocol DetectionPreferenceStoring {
    var enabled: Bool { get set }
}

/// UserDefaults-backed detection flag. Defaults to `false` when unset
/// (`UserDefaults.bool(forKey:)` returns `false` for a missing key).
struct DetectionPreference: DetectionPreferenceStoring {
    private let defaults: UserDefaults
    private let key = "vibecheck.detection.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
