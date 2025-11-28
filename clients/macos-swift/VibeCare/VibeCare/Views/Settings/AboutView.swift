import SwiftUI
import WebKit

/// WebView wrapper for displaying web content using WKWebView
struct WebView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> WKWebView {
    let webView = WKWebView()
    webView.load(URLRequest(url: url))
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    // Only reload if URL changed
    if nsView.url != url {
      nsView.load(URLRequest(url: url))
    }
  }
}

/// About view that displays the VibeCare website
struct AboutView: View {
  private let websiteURL = URL(string: "https://vibecare.io")!

  var body: some View {
    WebView(url: websiteURL)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  AboutView()
    .frame(width: 800, height: 600)
}
