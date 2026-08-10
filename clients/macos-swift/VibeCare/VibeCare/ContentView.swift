import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var backend = BackendManager.shared

    var body: some View {
        switch backend.state {
        case .starting:
            startingContent
        case .failed(let message):
            failedContent(message: message)
        case .ready:
            VStack(spacing: 0) {
                if backend.backendStale {
                    backendStaleBanner
                }
                readyContent
            }
        }
    }

    @ViewBuilder
    private var backendStaleBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
            Text("A new version is installed — restart the backend to apply it.")
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            if backend.state == .starting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Restart") {
                    Task {
                        await backend.restart()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var startingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Starting VibeCare…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func failedContent(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await backend.ensureRunning()
                }
            }
            .buttonStyle(.borderedProminent)
            Text("See ~/.vibecare/logs/server.log")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var readyContent: some View {
        Group {
            if horizontalSizeClass == .compact {
                CompactDashboard()
            } else {
                Dashboard()
            }
        }
        .sheet(isPresented: $appState.showProfileSelector) {
            ProfileSelectorView()
                .environmentObject(appState)
                .interactiveDismissDisabled(appState.currentProfile == nil) // Can't dismiss if no profile selected
        }
        .alert("Connection Error", isPresented: $appState.showConnectionError) {
            Button("Retry") {
                Task {
                    await appState.loadInitialData()
                }
            }
            Button("Settings") {
                #if os(macOS)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                #endif
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Unable to connect to VibeCare backend. Please check your connection settings.")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
