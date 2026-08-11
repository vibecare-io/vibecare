import Foundation

/// Minimal update check (KISS): compares the installed app version to the
/// latest GitHub release tag. No auto-update, no download — just "is a newer
/// version available?" so the About settings can tell the user to `brew upgrade`.
enum UpdateChecker {
    /// github.com's "latest release" endpoint. Hitting this (rather than
    /// `api.github.com`) avoids the unauthenticated REST API's 60-req/hr rate
    /// limit — that limit returns HTTP 403 once exhausted and caused intermittent
    /// "couldn't check for updates". The web endpoint 302-redirects to
    /// `.../releases/tag/<tag>`, so the tag is right in the `Location` header.
    static let latestReleaseURL =
        URL(string: "https://github.com/vibecare-io/vibecare/releases/latest")!

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

    /// Extracts the tag from a `…/releases/tag/<tag>` redirect Location.
    /// Pure + testable.
    static func tag(fromLocation location: String) -> String? {
        guard let range = location.range(of: "/releases/tag/") else { return nil }
        let tag = String(location[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return tag.isEmpty ? nil : tag
    }

    /// Fetches the latest release tag by reading the 302 redirect's `Location`
    /// header (does NOT follow the redirect, so no extra request and no API
    /// rate limit). Returns nil on any failure — the caller shows a soft retry.
    static func latestVersion() async -> String? {
        var req = URLRequest(url: latestReleaseURL)
        req.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        guard let (_, resp) = try? await session.data(for: req, delegate: NoRedirectDelegate()),
              let http = resp as? HTTPURLResponse,
              (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location")
        else { return nil }
        return tag(fromLocation: location)
    }
}

/// URLSession delegate that stops at the first redirect so we can read its
/// `Location` header instead of following it.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
