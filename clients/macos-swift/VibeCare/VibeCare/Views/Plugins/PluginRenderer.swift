import SwiftUI
import VCStubs

/// Callback invoked when a rendered node fires an interaction (toggle
/// change, text submit, button tap). `action` and `params` come straight
/// off the `Node` that triggered the interaction; callers merge in any
/// additional values (e.g. entered text) before invoking.
typealias PluginInvoke = (_ action: String, _ params: [String: String]) -> Void

/// Renders a plugin's declarative `Vibecare_Plugin_V1_Node` tree as native
/// SwiftUI. This is the ONLY place that interprets `Node.kind` - the client
/// never talks to a plugin directly, it only walks the tree Core returned
/// from `renderView`/`invoke`.
///
/// Because the node tree is heterogeneous (a `list` node's children may be
/// `row`s, a `row`'s children may be `text`/`toggle`/`button`, etc.),
/// recursive rendering returns `AnyView`. This keeps the kind→view mapping
/// in one pure, readable function that's easy to eyeball-verify (and to
/// unit test later once a test target exists).
enum PluginRenderer {
    /// Renders a single node (and, recursively, its children) into SwiftUI.
    ///
    /// - Parameters:
    ///   - node: The node to render.
    ///   - invoke: Called with an action id + params whenever the user
    ///     interacts with a `toggle`, `textField`, or `button` node.
    @MainActor
    static func render(_ node: Vibecare_Plugin_V1_Node, invoke: @escaping PluginInvoke) -> AnyView {
        switch node.kind {
        case "list":
            return AnyView(
                List {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                        render(child, invoke: invoke)
                    }
                }
            )

        case "row":
            return AnyView(
                HStack {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                        render(child, invoke: invoke)
                    }
                }
            )

        case "text":
            return AnyView(Text(node.text))

        case "toggle":
            return AnyView(ToggleNodeView(node: node, invoke: invoke))

        case "textField":
            return AnyView(TextFieldNodeView(node: node, invoke: invoke))

        case "button":
            return AnyView(
                Button(node.text) {
                    invoke(node.action, node.params)
                }
            )

        case "spacer":
            return AnyView(Spacer())

        default:
            // Unknown kind: don't crash, just render nothing. Plugins
            // running against a newer node vocabulary than this client
            // still degrade gracefully.
            return AnyView(EmptyView())
        }
    }
}

// MARK: - Stateful node views

/// `toggle` nodes are bound DIRECTLY to `node.boolValue` via a computed
/// `Binding` - deliberately no local `@State` here.
///
/// Why: SwiftUI only honors a `@State` property's *initial* value the
/// first time a view's identity is created; on every subsequent re-render
/// (e.g. `ForEach`'s index-identity reusing this view after `descriptor`
/// changes), a freshly-computed `initialValue` passed into `init` is
/// silently ignored and the persisted `@State` storage wins. A prior
/// version of this view seeded `@State private var isOn` from
/// `node.boolValue` in `init` and flipped it optimistically in
/// `onChange` - but that meant a FAILED invoke (where `node.boolValue`
/// never actually changes, since `PluginScreen` intentionally keeps the
/// last-good `descriptor` on error) left `isOn` permanently stuck at the
/// optimistic value with no way to resync it, since there's no "value
/// changed" signal to hang a fix on.
///
/// Binding directly to `node.boolValue` sidesteps the whole problem: the
/// switch always reflects the freshest server-confirmed state, with zero
/// possibility of drift. The trade-off is no instant optimistic flip on
/// tap - the switch visually updates once `PluginScreen` receives and
/// assigns the new descriptor (fast on a local backend, but not
/// synchronous with the tap gesture).
private struct ToggleNodeView: View {
    let node: Vibecare_Plugin_V1_Node
    let invoke: PluginInvoke

    var body: some View {
        Toggle(
            node.text,
            isOn: Binding(
                get: { node.boolValue },
                set: { _ in invoke(node.action, node.params) }
            )
        )
    }
}

/// `textField` nodes use `node.text` as the placeholder (per contract) and
/// keep the entered value in local `@State`. On submit, the entered text is
/// merged into `node.params` under the `"text"` key before invoking.
private struct TextFieldNodeView: View {
    let node: Vibecare_Plugin_V1_Node
    let invoke: PluginInvoke

    @State private var text: String = ""

    var body: some View {
        TextField(node.text, text: $text)
            .onSubmit {
                var params = node.params
                params["text"] = text
                invoke(node.action, params)
                text = ""
            }
    }
}
