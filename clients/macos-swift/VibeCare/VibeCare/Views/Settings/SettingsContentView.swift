import SwiftUI

struct SettingsContentView: View {
    var body: some View {
        VStack {
            EmptyStateView(
                title: "Settings",
                subtitle: "Configure your VibeCare preferences",
                systemImage: "gearshape.circle"
            )
        }
        .navigationTitle("Settings")
    }
}

struct SettingsView: View {
    var body: some View {
        SettingsContentView()
    }
}

#Preview {
    SettingsContentView()
}