import SwiftUI
import WebKit

/// A plugin's screen. The shell embeds the plugin's own HTTP surface and
/// knows nothing about what it renders — that is D4, and it is why adding
/// a plugin never requires releasing the client.
struct PluginWebView: NSViewRepresentable {
    let url: URL
    /// Changing this forces a reload — used when a plugin transitions back
    /// to `up` so the user is not left on core's error page.
    let reloadToken: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Plugins are first-party and served from core's loopback origin.
        let view = WKWebView(frame: .zero, configuration: config)
        // `setValue(_:forKey: "drawsBackground")` is undocumented KVC on
        // WKWebView that can throw at runtime; `underPageBackgroundColor`
        // is the supported, public API (macOS 12+) for the same effect.
        view.underPageBackgroundColor = .clear
        context.coordinator.loaded = nil
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reload only when the target actually changed; SwiftUI calls this
        // on every parent redraw and reloading each time would reset the
        // plugin's scroll position and form state.
        let key = url.absoluteString + "|" + reloadToken
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: String?
    }
}
