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
        // Alerts are the one UI path that is not HTML, because they must
        // render with no window open and with the webview never loaded.
        switch alert.level {
        case "warn":
            NotificationManager.shared.showWarning(title: alert.title, message: alert.body)
        default:
            NotificationManager.shared.showInfo(title: alert.title, message: alert.body)
        }
        if !alert.actions.isEmpty {
            // Rendering action buttons needs a notification API this shell
            // does not yet have; the actions are carried on the model so
            // adding it later touches nothing else.
            logger.info("Alert from \(alert.plugin) carried \(alert.actions.count) unrendered action(s)")
        }
    }
}
