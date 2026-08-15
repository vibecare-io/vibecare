import Foundation
import VCStubs

/// A plugin's lifecycle state, mirrored from the roster stream.
///
/// `degraded` is deliberately distinct from `down`: the tab still loads but
/// the plugin is misbehaving, and collapsing the two would make that
/// indistinguishable from a slow plugin.
enum PluginState: String, Sendable {
    case starting, up, degraded, down, failed

    init(protoState: VCKState) {
        switch protoState {
        case .up: self = .up
        case .degraded: self = .degraded
        case .down: self = .down
        case .failed: self = .failed
        default: self = .starting
        }
    }
}

/// One row in the plugin sidebar.
///
/// The client contains NO plugin-specific code: this is everything the
/// shell knows about any plugin, and `path` is a URL, never a schema.
struct PluginEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let icon: String
    /// "/p/todo/" — supplied by core and stable across plugin restarts, so
    /// it is used verbatim rather than rebuilt from `id`.
    let path: String
    let state: PluginState
    /// Exit reason when down/failed; /health detail when degraded.
    let detail: String

    /// Whether the plugin is actually serving HTTP right now. A degraded
    /// plugin still serves — that is the whole distinction from down.
    var isViewable: Bool { state == .up || state == .degraded }

    /// Changes whenever the plugin's serving status changes, so SwiftUI
    /// rebuilds the webview when a plugin comes back and the user is not
    /// left on a stale error page.
    var reloadToken: String { "\(id):\(state.rawValue)" }
}

/// The whole roster, plus the origin and token needed to reach any of it.
struct PluginRoster: Equatable, Sendable {
    let plugins: [PluginEntry]
    let baseURL: String
    let token: String

    static let empty = PluginRoster(plugins: [], baseURL: "", token: "")

    /// The sidebar id for core's own built-in status dashboard row (D12).
    /// A leading underscore can never collide with a real plugin id — core
    /// rejects manifest ids that start with one (§4), for exactly this
    /// reason: `/_core/*` is reserved.
    static let coreStatusID = "_core"

    /// The URL for a plugin's INITIAL load. The token rides along exactly
    /// once: core validates it, sets an HttpOnly cookie, and redirects it
    /// away, so it never lands in history or a Referer header.
    func handoffURL(for entry: PluginEntry) -> URL? {
        guard var comps = URLComponents(string: baseURL), !baseURL.isEmpty else { return nil }
        comps.path = entry.path
        comps.queryItems = [URLQueryItem(name: "vc", value: token)]
        return comps.url
    }

    /// A URL for a plugin-relative path — e.g. an alert action, which
    /// reuses the proxy rather than inventing a callback channel.
    ///
    /// `path` may carry its own query string (action URLs like
    /// `api/snooze?minutes=10` do) — that part must go through
    /// `URLComponents.query`, not `.path`, or the `?` gets percent-encoded
    /// into a literal path character instead of starting a query.
    func url(for entry: PluginEntry, path: String) -> URL? {
        guard var comps = URLComponents(string: baseURL), !baseURL.isEmpty else { return nil }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let qIndex = suffix.firstIndex(of: "?") {
            comps.path = entry.path + suffix[suffix.startIndex..<qIndex]
            comps.query = String(suffix[suffix.index(after: qIndex)...])
        } else {
            comps.path = entry.path + suffix
        }
        return comps.url
    }

    /// The URL for core's own built-in status dashboard (`/_core/status`,
    /// D12) — the same handoff as `handoffURL`, but pointed at core's path
    /// instead of a plugin's. This is what lets the shell render the
    /// dashboard with the exact same `PluginWebView` it uses for any
    /// plugin: core's HTML/JSON split (§7.4) means `/_core/status` is
    /// authenticated and served exactly like `/p/<id>/`, so no parallel
    /// client-side path is needed for it.
    func coreStatusURL() -> URL? {
        guard var comps = URLComponents(string: baseURL), !baseURL.isEmpty else { return nil }
        comps.path = "/_core/status"
        comps.queryItems = [URLQueryItem(name: "vc", value: token)]
        return comps.url
    }

    func entry(id: String) -> PluginEntry? { plugins.first { $0.id == id } }

    /// A URL for a plugin-relative path, resolved by plugin id rather than
    /// an already-known `PluginEntry` — what an alert action has (`alert.plugin`
    /// is a bare string), not what the sidebar has. Unlike `url(for:path:)`,
    /// this can genuinely fail: the plugin named on the alert may no longer
    /// be in the roster (e.g. it died between sending the alert and the
    /// button being pressed), and that must resolve to nil rather than a
    /// malformed URL.
    func url(for pluginID: String, path: String) -> URL? {
        guard let entry = entry(id: pluginID) else { return nil }
        return url(for: entry, path: path)
    }
}

/// A transient, native notification originating from a plugin.
struct PluginAlertAction: Equatable, Sendable {
    let label: String
    let url: String  // plugin-relative
}

struct PluginAlert: Identifiable, Equatable, Sendable {
    let id: UUID
    let plugin: String
    let title: String
    let body: String
    let level: String  // "info" | "warn"
    let actions: [PluginAlertAction]

    init(proto: VCKAlert) {
        self.id = UUID()
        self.plugin = proto.plugin
        self.title = proto.title
        self.body = proto.body
        self.level = proto.level
        self.actions = proto.actions.map { PluginAlertAction(label: $0.label, url: $0.url) }
    }
}
