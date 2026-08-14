import SwiftUI

/// Detail view for the selected plugin: its own HTML, served by the plugin
/// itself and proxied by core. The client knows only a URL.
struct PluginScreen: View {
    @ObservedObject var shell: PluginShellService
    let pluginId: String

    var body: some View {
        Group {
            if let plugin = shell.roster.entry(id: pluginId) {
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
        .navigationTitle(shell.roster.entry(id: pluginId)?.name ?? pluginId)
    }
}
