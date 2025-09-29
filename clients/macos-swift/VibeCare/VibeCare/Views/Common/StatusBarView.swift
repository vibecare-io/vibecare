import SwiftUI

struct StatusBarView: View {
    @ObservedObject private var statusManager = StatusBarManager.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if statusManager.isVisible, let message = statusManager.currentMessage {
                HStack(spacing: 12) {
                    // Icon or progress indicator
                    if message.type == .loading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: message.type.icon)
                            .foregroundColor(message.type.color)
                            .font(.system(size: 16))
                    }

                    // Message text
                    Text(message.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    // Dismiss button for important messages
                    if message.type == .error || message.type == .warning {
                        Button {
                            statusManager.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        // Background with blur
                        VisualEffectBackground()

                        // Colored accent line at top
                        VStack {
                            Rectangle()
                                .fill(message.type.color)
                                .frame(height: 2)
                            Spacer()
                        }
                    }
                )
                .cornerRadius(0)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: -2)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: statusManager.isVisible)
            }
        }
    }
}

// Visual effect background for macOS
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// View modifier to easily add status bar to any view
struct StatusBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            content

            VStack {
                Spacer()
                StatusBarView()
            }
            .allowsHitTesting(false) // Don't block interactions with content
        }
    }
}

extension View {
    func withStatusBar() -> some View {
        modifier(StatusBarModifier())
    }
}

#Preview {
    VStack {
        Button("Show Success") {
            StatusBarManager.shared.showSuccess("Operation completed successfully!")
        }

        Button("Show Error") {
            StatusBarManager.shared.showError("Something went wrong")
        }

        Button("Show Loading") {
            StatusBarManager.shared.showLoading("Processing...")
        }

        Button("Show Info") {
            StatusBarManager.shared.showMessage("This is an info message", type: .info)
        }

        Spacer()
    }
    .frame(width: 600, height: 400)
    .withStatusBar()
}