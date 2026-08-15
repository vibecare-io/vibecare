import AppKit
import Foundation
import Logging
import SwiftProtobuf
import VCStubs

/// The client's entire plugin surface: two long-lived streams.
///
/// `Plugins` pushes the whole roster on any state change; `Intents` pushes
/// transient alerts. Nothing else — user input goes straight from the
/// webview to the plugin over HTTP, so there is no third channel.
@MainActor
final class PluginShellService: ObservableObject {
    @Published private(set) var roster: PluginRoster = .empty
    @Published private(set) var lastAlert: PluginAlert?

    private let logger = Logger(label: "com.vibecare.plugin-shell")
    private var rosterTask: Task<Void, Never>?
    private var intentsTask: Task<Void, Never>?

    /// Idempotent: a second `start()` while streams are already running is a
    /// no-op, so callers (e.g. a `.task` modifier that can re-fire) can't
    /// leak a duplicate pair of long-lived tasks.
    func start() {
        guard rosterTask == nil else { return }
        rosterTask = Task { [weak self] in await self?.streamRoster() }
        intentsTask = Task { [weak self] in await self?.streamIntents() }
    }

    func stop() {
        rosterTask?.cancel(); rosterTask = nil
        intentsTask?.cancel(); intentsTask = nil
    }

    // MARK: - Streams

    /// Both streams reconnect on their own: core restarting must not leave
    /// the sidebar permanently empty.
    private func streamRoster() async {
        while !Task.isCancelled {
            do {
                let _: Void = try await GRPCClientManager.shared.withShellClient { [weak self] client in
                    // Unwrap to a non-optional `let` before the nested
                    // @Sendable `onResponse` closure: capturing the
                    // still-optional `weak self` binding a second time,
                    // inside that nested closure, is what strict
                    // concurrency rejects (a `var`-like weak capture
                    // referenced from further concurrently-executing code).
                    guard let self else { return }
                    try await client.plugins(Google_Protobuf_Empty()) { response in
                        for try await list in response.messages {
                            await self.apply(list)
                        }
                        return Void()
                    }
                }
            } catch {
                logger.error("Roster stream ended: \(error)")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func streamIntents() async {
        while !Task.isCancelled {
            do {
                let _: Void = try await GRPCClientManager.shared.withShellClient { [weak self] client in
                    guard let self else { return }
                    try await client.intents(Google_Protobuf_Empty()) { response in
                        for try await intent in response.messages {
                            guard case .alert(let alert) = intent.k else { continue }
                            await self.deliver(PluginAlert(proto: alert))
                        }
                        return Void()
                    }
                }
            } catch {
                logger.error("Intents stream ended: \(error)")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ list: VCKPluginList) {
        roster = PluginRoster(
            plugins: list.plugins.map {
                PluginEntry(
                    id: $0.id,
                    name: $0.name,
                    icon: $0.icon,
                    path: $0.path,
                    state: PluginState(protoState: $0.state),
                    detail: $0.detail
                )
            },
            baseURL: list.baseURL,
            token: list.token
        )
        logger.info("Roster updated: \(roster.plugins.count) plugins at \(roster.baseURL)")
    }

    private func deliver(_ alert: PluginAlert) {
        lastAlert = alert
        let buttons = alert.actions.map { action in
            NotificationAction(label: action.label) { [weak self] in
                // The button's `action` closure is VibeNotify's own type
                // (`() -> Void`, not `@MainActor`), so hop back onto the
                // main actor explicitly rather than assuming the call site
                // is already isolated.
                Task { @MainActor in
                    self?.performAction(action, plugin: alert.plugin)
                }
            }
        }

        // A plugin may attach presentation hints to its own alert. The shell
        // still contains no plugin-specific code: it decodes a shape it
        // already owns (`NotificationPreferences`, the same one the schedule
        // notification editor writes) and ignores anything else, so a plugin
        // opts into a styled alert without any client release.
        //
        // Title and body come from the ALERT, never from the decoded
        // preferences: the sender already applied whatever custom wording it
        // has, plus anything it computed at fire time (a running count, say).
        // Re-reading `prefs.title` here would silently throw that away.
        guard let preferences = alert.appearancePreferences else {
            // No appearance: byte-for-byte the behaviour that shipped before
            // alerts could carry one.
            switch alert.level {
            case "warn":
                NotificationManager.shared.showWarning(title: alert.title, message: alert.body, actions: buttons)
            default:
                NotificationManager.shared.showInfo(title: alert.title, message: alert.body, actions: buttons)
            }
            return
        }

        // Resolving the icon means an HTTP fetch through the proxy, so the
        // presentation is deferred by one hop. It is bounded (2s, below) and
        // failure still shows the alert — just with the fallback icon.
        Task { [weak self] in
            guard let self else { return }
            let image = await self.resolveIcon(for: alert, preferences: preferences)
            NotificationManager.shared.showStyledPluginAlert(
                title: alert.title,
                message: alert.body,
                preferences: preferences,
                level: alert.level,
                actions: buttons,
                iconImage: image
            )
        }
    }

    /// Bounded cache of already-fetched alert icons, keyed by absolute URL.
    /// Detection-style alerts reuse one icon over and over, and refetching a
    /// few KB through the proxy on every single alert would add latency to
    /// the one UI path that is supposed to appear instantly.
    private var iconCache: [String: NSImage] = [:]
    private static let iconCacheLimit = 16
    private static let iconFetchTimeout: TimeInterval = 2

    /// Materializes the appearance's icon as an `NSImage` — `NSImage`
    /// decodes SVG natively — so the alert can show it on VibeNotify's
    /// standard renderer, the only one that also draws buttons. See
    /// `VibeNotifyConfig.showNotification`'s doc comment for that trade.
    ///
    /// A relative `svgPath` is resolved against the SENDING plugin's own
    /// mount. That rule is generic, not plugin knowledge: everything a
    /// plugin serves lives under `/p/<id>/`, which is the same resolution
    /// `performAction` already does for action URLs.
    private func resolveIcon(for alert: PluginAlert, preferences: NotificationPreferences) async -> NSImage? {
        guard let path = preferences.resolvedSVGPath, !path.isEmpty else { return nil }

        // Local files never go through the proxy.
        if path.hasPrefix("file://") {
            return URL(string: path).flatMap { NSImage(contentsOf: $0) }
        }
        if path.hasPrefix("/") {
            return NSImage(contentsOfFile: path)
        }

        let resolved: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            resolved = URL(string: path)
        } else {
            resolved = roster.url(for: alert.plugin, path: path)
        }
        guard let url = resolved else {
            logger.error("Cannot resolve alert icon '\(path)' for plugin \(alert.plugin)")
            return nil
        }
        if let cached = iconCache[url.absoluteString] { return cached }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.iconFetchTimeout
        // Same session cookie the webviews and alert actions authenticate
        // with; core's proxy rejects an unauthenticated /p/<id>/ request.
        request.setValue("vc_session=\(roster.token)", forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = NSImage(data: data) else {
                logger.error("Alert icon \(url.absoluteString) did not decode; falling back to the default icon")
                return nil
            }
            if iconCache.count >= Self.iconCacheLimit { iconCache.removeAll() }
            iconCache[url.absoluteString] = image
            return image
        } catch {
            logger.error("Alert icon \(url.absoluteString) failed to load: \(error)")
            return nil
        }
    }

    /// Runs a pressed alert action: a plain HTTP GET to the action's
    /// resolved URL through core's reverse proxy, carrying the same
    /// session cookie (`vc_session`) the shell's webviews authenticate
    /// with. No new callback channel and no core change — the plugin's
    /// action endpoints accept both GET and POST for exactly this reason.
    ///
    /// A failure here is logged and never surfaced as a second
    /// notification: an error banner because a snooze failed is worse than
    /// a silent failure — the user asked for less interruption, not more.
    private func performAction(_ action: PluginAlertAction, plugin: String) {
        guard let url = roster.url(for: plugin, path: action.url) else {
            logger.error("Cannot resolve URL for action '\(action.label)' from plugin \(plugin) (not in the current roster)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Same cookie value core hands the webview via Set-Cookie on the
        // ?vc= handoff (`vc_session`, backend/kernel/auth.go) — the shell
        // already holds it as `roster.token` regardless of whether any
        // webview for this plugin has ever loaded.
        request.setValue("vc_session=\(roster.token)", forHTTPHeaderField: "Cookie")
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    logger.error("Alert action '\(action.label)' for \(plugin) returned HTTP \(status)")
                    return
                }
                logger.info("Alert action '\(action.label)' for \(plugin) succeeded")
            } catch {
                logger.error("Alert action '\(action.label)' for \(plugin) failed: \(error)")
            }
        }
    }
}
