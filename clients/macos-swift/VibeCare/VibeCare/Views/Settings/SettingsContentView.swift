import SwiftUI

public struct SettingsContentView: View {
    public var body: some View {
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

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        SettingsContentView()
    }
}

#Preview {
    SettingsContentView()
}