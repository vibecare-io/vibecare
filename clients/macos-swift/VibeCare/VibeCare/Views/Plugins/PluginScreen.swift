import SwiftUI

/// Detail view for the selected plugin: its own HTML, served by the plugin
/// itself and proxied by core. The client knows only a URL.
struct PluginScreen: View {
    @ObservedObject var shell: PluginShellService
    let pluginId: String

    var body: some View {
        Group {
            // Core's own status dashboard (D12) — rendered by the exact same
            // PluginWebView as any plugin, just pointed at core's own path
            // instead of a plugin's. No parallel client-side path: this is
            // the one extra branch the built-in row needs.
            if pluginId == PluginRoster.coreStatusID {
                if let url = shell.roster.coreStatusURL() {
                    PluginWebView(url: url, reloadToken: "core-status:\(shell.roster.baseURL)")
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let plugin = shell.roster.entry(id: pluginId) {
                if plugin.isViewable, let url = shell.roster.handoffURL(for: plugin) {
                    PluginWebView(url: url, reloadToken: plugin.reloadToken)
                } else {
                    EmptyStateView(
                        title: "\(plugin.name) is \(plugin.state.rawValue)",
                        subtitle: plugin.detail.isEmpty
                            ? "This view reloads automatically when the plugin comes back."
                            : plugin.detail,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(pluginId == PluginRoster.coreStatusID ? "Status" : (shell.roster.entry(id: pluginId)?.name ?? pluginId))
    }
}
