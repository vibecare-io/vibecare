import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
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
