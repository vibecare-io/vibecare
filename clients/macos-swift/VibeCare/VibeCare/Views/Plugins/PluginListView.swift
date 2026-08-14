import SwiftUI

/// The plugin sidebar. It renders whatever the roster says and contains no
/// plugin-specific code — adding a plugin never touches this file.
struct PluginListView: View {
    @ObservedObject var shell: PluginShellService
    @Binding var selectedId: String?

    var body: some View {
        Group {
            if shell.roster.plugins.isEmpty {
                EmptyStateView(
                    title: "No Plugins",
                    subtitle: "Drop a plugin into the plugins directory and restart the backend.",
                    systemImage: "puzzlepiece.extension"
                )
            } else {
                List(shell.roster.plugins, selection: $selectedId) { plugin in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name)
                            if plugin.state != .up {
                                Text(statusLine(for: plugin))
                                    .font(.caption)
                                    .foregroundStyle(color(for: plugin.state))
                            }
                        }
                    }
                    .tag(plugin.id)
                }
            }
        }
        .navigationTitle("Plugins")
    }

    private func statusLine(for plugin: PluginEntry) -> String {
        plugin.detail.isEmpty ? plugin.state.rawValue : "\(plugin.state.rawValue) — \(plugin.detail)"
    }

    private func color(for state: PluginState) -> Color {
        switch state {
        case .up: return .green
        case .degraded: return .orange
        case .down, .failed: return .red
        case .starting: return .secondary
        }
    }
}
