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
            // IMPORTANT: `descriptor` wins over `errorMessage` whenever we
            // have one. A transient invoke failure (toggle/delete/add) must
            // NOT blank out an already-loaded list - it should surface
            // non-destructively (see `.alert` below) while the last-good
            // content stays visible and interactive. The full-screen error
            // branch below only applies when there's nothing to show yet
            // (i.e. the initial load itself failed).
            if let descriptor {
                VStack(spacing: 0) {
                    ForEach(Array(descriptor.nodes.enumerated()), id: \.offset) { _, node in
                        PluginRenderer.render(node, invoke: invoke)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(pluginId)
        // Keyed on pluginId so switching to a different plugin (which reuses
        // this same view identity in Dashboard's detail column) cancels the
        // old load and re-runs load() for the newly-selected plugin. A plain
        // `.task {}` only fires once per view identity and would leave the
        // previous plugin's descriptor on screen.
        .task(id: pluginId) {
            await load()
        }
        // Non-destructive surface for an invoke() failure that happened
        // AFTER we already have a descriptor on screen: a dismissible
        // alert layered on top, not a takeover of the whole view. Only
        // shown once we have content (the full-screen branch above already
        // covers "no descriptor yet" failures).
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { descriptor != nil && errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            ),
            actions: {
                Button("OK") { errorMessage = nil }
            },
            message: {
                Text(errorMessage ?? "")
            }
        )
    }

    private func load() async {
        // Reset per-plugin state up front so switching plugins shows the
        // loading spinner for the new one rather than briefly leaving the
        // previous plugin's list on screen (this @State persists across the
        // reused view identity - see the `.task(id:)` note above).
        descriptor = nil
        errorMessage = nil
        do {
            let loaded = try await pluginService.renderView(pluginId: pluginId, viewId: viewId)
            // If this load was superseded (pluginId changed, cancelling the
            // task), don't clobber the newer plugin's state.
            if Task.isCancelled { return }
            descriptor = loaded
        } catch {
            if Task.isCancelled { return }
            errorMessage = "Failed to load plugin view: \(error.localizedDescription)"
        }
    }

    /// Passed to `PluginRenderer` as the interaction callback. Invokes the
    /// action on Core and, on success, swaps in the freshly-returned
    /// descriptor (whole-view refresh - no diffing in v1). On failure,
    /// `descriptor` is left untouched (so the last-good content keeps
    /// rendering) and `errorMessage` is surfaced via the non-destructive
    /// `.alert` above.
    private func invoke(action: String, params: [String: String]) {
        Task {
            errorMessage = nil
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
