import SwiftUI

struct PluginListView: View {
    @Binding var selectedId: String?

    @StateObject private var pluginService = PluginService()
    @State private var plugins: [PluginSummary] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading plugins…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plugins.isEmpty {
                EmptyStateView(
                    title: "No Plugins",
                    subtitle: "No plugins are currently installed",
                    systemImage: "puzzlepiece.extension"
                )
            } else {
                List(selection: $selectedId) {
                    ForEach(plugins) { plugin in
                        PluginRow(plugin: plugin)
                            .tag(plugin.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Plugins")
        .task {
            await loadPlugins()
        }
    }

    private func loadPlugins() async {
        isLoading = true
        plugins = await pluginService.listPlugins()
        isLoading = false
    }
}

// MARK: - Plugin Row

private struct PluginRow: View {
    let plugin: PluginSummary

    var body: some View {
        HStack {
            Image(systemName: plugin.icon.isEmpty ? "puzzlepiece.extension" : plugin.icon)
                .foregroundColor(.teal)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.headline)
                Text(plugin.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    PluginListView(selectedId: .constant(nil))
}
