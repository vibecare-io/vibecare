import Foundation

/// Loads the packaged `ui/` directory, WITHOUT `Bundle.module`.
///
/// SwiftPM's generated `Bundle.module` accessor is a `let` whose failure path
/// is `fatalError`, and a plugin that hard-aborts over a missing resource is
/// charged an unrequested exit by `supervisor.go` — five of those park it in
/// `StateFailed`, recoverable only by a manual dashboard restart. Resolve by
/// hand and let a miss be a 500 an operator can see. Same reasoning, same
/// shape, as vibecheck's `uiResourceURL`.
public enum VisionUI {
    /// Ordered by likelihood, not by preference: the first candidate is what
    /// `just build-vision-plugin` and `just install-plugins` actually lay
    /// down, and the second is a bare `ui/` dropped beside the binary, which
    /// is what someone debugging an install reaches for first.
    public static func resourceURL(_ relative: String) -> URL? {
        let base = Bundle.main.bundleURL
        let candidates = [
            base.appendingPathComponent("vision_VisionAPI.bundle").appendingPathComponent(relative),
            base.appendingPathComponent(relative),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The default `loadUI` for `registerVisionRoutes`. Returns `nil` rather
    /// than throwing on a missing or unreadable file — the route turns that
    /// into a 500 and the process stays up.
    public static func load(_ relative: String) -> Data? {
        guard let url = resourceURL(relative) else { return nil }
        return try? Data(contentsOf: url)
    }
}
