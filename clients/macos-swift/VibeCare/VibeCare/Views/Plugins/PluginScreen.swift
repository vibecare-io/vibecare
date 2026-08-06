import SwiftUI

/// Detail view for a selected plugin.
///
/// TODO(Task 9): render ViewDescriptor natively - this is currently a
/// minimal placeholder. Task 9 replaces the body with a declarative
/// renderer that walks the `Vibecare_Plugin_V1_ViewDescriptor` returned by
/// `PluginService.renderView` / `PluginService.invoke` and builds SwiftUI
/// views from its `Node` tree. The `pluginId` signature below is kept
/// stable so Task 9 only needs to change internals.
struct PluginScreen: View {
    let pluginId: String

    @StateObject private var pluginService = PluginService()
    @State private var pluginName: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundColor(.teal)

            Text(pluginName ?? pluginId)
                .font(.title2)
                .fontWeight(.semibold)

            if isLoading {
                ProgressView("Loading…")
            } else {
                Text("Plugin view rendering is not yet implemented.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(pluginName ?? pluginId)
        .task {
            await loadPluginName()
        }
    }

    private func loadPluginName() async {
        isLoading = true
        let plugins = await pluginService.listPlugins()
        pluginName = plugins.first(where: { $0.id == pluginId })?.name
        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    PluginScreen(pluginId: "todos")
}
