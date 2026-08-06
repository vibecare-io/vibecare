import SwiftUI
import VCStubs

/// Detail view for a selected plugin.
///
/// Loads the plugin's "main" view descriptor from Core (`renderView`) and
/// renders it natively via `PluginRenderer`. Interactions (`toggle`,
/// `textField`, `button`) round-trip through `PluginService.invoke`, and
/// the returned descriptor wholesale-replaces `descriptor` - v1 has no
/// diffing model, the whole tree is just re-rendered.
///
/// The client never talks to a plugin directly; all communication goes
/// through `PluginService`, which is Core's `PluginHostService` client.
struct PluginScreen: View {
    let pluginId: String

    /// v1 only exposes a single entry view per plugin, and the todos
    /// plugin's SDK registers it under this id. If plugins ever expose
    /// multiple named views, this should come from the selected plugin's
    /// `uiEntry` (see `PluginSummary.uiEntry`) instead of being hardcoded.
    private let viewId = "main"

    @StateObject private var pluginService = PluginService()
    @State private var descriptor: Vibecare_Plugin_V1_ViewDescriptor?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let descriptor {
                VStack(spacing: 0) {
                    ForEach(Array(descriptor.nodes.enumerated()), id: \.offset) { _, node in
                        PluginRenderer.render(node, invoke: invoke)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(pluginId)
        .task {
            await load()
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            descriptor = try await pluginService.renderView(pluginId: pluginId, viewId: viewId)
        } catch {
            errorMessage = "Failed to load plugin view: \(error.localizedDescription)"
        }
    }

    /// Passed to `PluginRenderer` as the interaction callback. Invokes the
    /// action on Core and, on success, swaps in the freshly-returned
    /// descriptor (whole-view refresh - no diffing in v1).
    private func invoke(action: String, params: [String: String]) {
        Task {
            do {
                let updated = try await pluginService.invoke(
                    pluginId: pluginId,
                    viewId: viewId,
                    action: action,
                    params: params
                )
                descriptor = updated
            } catch {
                errorMessage = "Action failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    PluginScreen(pluginId: "todos")
}
#endif
