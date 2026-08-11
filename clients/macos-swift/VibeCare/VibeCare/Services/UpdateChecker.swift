import Foundation

/// Minimal update check (KISS): compares the installed app version to the
/// latest GitHub release tag. No auto-update, no download — just "is a newer
/// version available?" so the About settings can tell the user to `brew upgrade`.
enum UpdateChecker {
    static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/vibecare-io/vibecare/releases/latest")!

    /// A newer release exists iff the latest tag differs from the installed
    /// version. GitHub's "latest release" is authoritative (it's the newest
    /// published, non-prerelease release), so any difference means the user is
    /// behind — no version-string parsing needed.
    static func isUpdateAvailable(installed: String, latest: String) -> Bool {
        let l = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = installed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !i.isEmpty else { return false }
        return l != i
    }

    /// Fetches the latest release tag from GitHub. Returns nil on any failure
    /// (offline, rate-limited, etc.) — the caller shows a soft "try again".
    static func latestVersion() async -> String? {
        var req = URLRequest(url: latestReleaseURL)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }
        return tag
    }
}
