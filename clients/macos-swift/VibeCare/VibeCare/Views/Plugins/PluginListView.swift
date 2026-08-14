import SwiftUI
import AppKit

/// The plugin sidebar. It renders whatever the roster says and contains no
/// plugin-specific code — adding a plugin never touches this file.
struct PluginListView: View {
    @ObservedObject var shell: PluginShellService
    @Binding var selectedId: String?

    var body: some View {
        Group {
            // The status row is core's own built-in dashboard (D12) —
            // reachable even when no product plugin is installed, since
            // that is exactly when it matters most.
            if shell.roster.plugins.isEmpty && shell.roster.baseURL.isEmpty {
                EmptyStateView(
                    title: "No Plugins",
                    subtitle: "Drop a plugin into the plugins directory and restart the backend.",
                    systemImage: "puzzlepiece.extension"
                )
            } else {
                List(selection: $selectedId) {
                    if !shell.roster.baseURL.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .foregroundStyle(.secondary)
                            Text("Status")
                        }
                        .tag(PluginRoster.coreStatusID)
                    }
                    ForEach(shell.roster.plugins) { plugin in
                        HStack(spacing: 8) {
                            Image(systemName: iconName(for: plugin))
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
        }
        .navigationTitle("Plugins")
    }

    /// Core supplies an icon per plugin (`PluginEntry.icon`, an SF Symbol
    /// name) — falls back to the generic puzzle-piece glyph when it's empty
    /// or not a name AppKit actually recognizes, so a typo'd/unknown symbol
    /// from a plugin manifest never renders as a blank row.
    private func iconName(for plugin: PluginEntry) -> String {
        guard !plugin.icon.isEmpty,
              NSImage(systemSymbolName: plugin.icon, accessibilityDescription: nil) != nil
        else {
            return "puzzlepiece.extension"
        }
        return plugin.icon
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
