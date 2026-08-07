import Foundation
import CoreGraphics

/// Trims whitespace; returns nil for empty/whitespace-only strings so an empty
/// override field falls back to the behavior default.
private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Window/behavior knobs for a detection alert. `.default` reproduces the
/// previously hardcoded `showBFRBAlert` values so the shipped default is a no-op.
struct DetectionAlertAppearance: Codable, Equatable {
    var position: NotificationPosition
    var width: CGFloat
    var height: CGFloat
    var moveable: Bool
    var screenBlurEnabled: Bool
    var screenBlurIntensity: BlurIntensity
    var autoDismissAfter: TimeInterval

    static let `default` = DetectionAlertAppearance(
        position: .center, width: 480, height: 300, moveable: true,
        screenBlurEnabled: true, screenBlurIntensity: .medium, autoDismissAfter: 6.0)

    static let minimal = DetectionAlertAppearance(
        position: .topRight, width: 350, height: 150, moveable: false,
        screenBlurEnabled: false, screenBlurIntensity: .light, autoDismissAfter: 5.0)

    static let prominent = DetectionAlertAppearance(
        position: .center, width: 500, height: 320, moveable: true,
        screenBlurEnabled: true, screenBlurIntensity: .heavy, autoDismissAfter: 8.0)
}

/// Resolved icon for the alert view.
enum DetectionAlertIcon: Equatable {
    case symbol(String)                    // SF Symbol (per-behavior default)
    case svg(path: String, size: CGSize)   // custom SVG override
}

/// Per-behavior customization. Empty/nil overrides fall back to the behavior's
/// built-in `label`/`nudge`/`alertIcon`.
struct DetectionAlertBehaviorPrefs: Codable, Equatable {
    var titleOverride: String?
    var messageOverride: String?
    var iconSVGPath: String?
    var iconSVGWidth: CGFloat?
    var iconSVGHeight: CGFloat?
    var overridesAppearance: Bool = false
    var appearance: DetectionAlertAppearance = .default
}

/// Full detection-alert preferences: one shared appearance plus per-behavior
/// entries keyed by `BFRBBehavior.rawValue`.
struct DetectionAlertPreferences: Codable, Equatable {
    var shared: DetectionAlertAppearance = .default
    var perBehavior: [String: DetectionAlertBehaviorPrefs] = [:]

    func effectiveAppearance(for b: BFRBBehavior) -> DetectionAlertAppearance {
        let p = perBehavior[b.rawValue]
        return (p?.overridesAppearance == true) ? p!.appearance : shared
    }

    func effectiveTitle(for b: BFRBBehavior) -> String {
        perBehavior[b.rawValue]?.titleOverride?.nonEmpty ?? b.label
    }

    func effectiveMessage(for b: BFRBBehavior) -> String {
        perBehavior[b.rawValue]?.messageOverride?.nonEmpty ?? b.nudge
    }

    func effectiveIcon(for b: BFRBBehavior) -> DetectionAlertIcon {
        if let path = perBehavior[b.rawValue]?.iconSVGPath?.nonEmpty {
            let w = perBehavior[b.rawValue]?.iconSVGWidth ?? 64
            let h = perBehavior[b.rawValue]?.iconSVGHeight ?? 64
            return .svg(path: path, size: CGSize(width: w, height: h))
        }
        return .symbol(b.alertIcon)
    }
}
