import SwiftUI

struct SettingsDetailView: View {
    let selectedSetting: SettingCategory?

    var body: some View {
        Group {
            if let setting = selectedSetting {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Setting Header
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: setting.iconName)
                                    .font(.title)
                                    .foregroundColor(setting.color)

                                VStack(alignment: .leading) {
                                    Text(setting.title)
                                        .font(.largeTitle)
                                        .fontWeight(.bold)

                                    Text(setting.description)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                        }

                        Divider()

                        // Setting Details based on category
                        switch setting {
                        case .profile:
                            ProfileSettingsDetail()
                        case .general:
                            GeneralSettingsDetail()
                        case .notifications:
                            NotificationsSettingsDetail()
                        case .network:
                            NetworkSettingsDetail()
                        case .appearance:
                            AppearanceSettingsDetail()
                        case .privacy:
                            PrivacySettingsDetail()
                        case .about:
                            AboutSettingsDetail()
                        }

                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Settings")
            } else {
                EmptyStateView(
                    title: "Select a Setting Category",
                    subtitle: "Choose a category from the settings to configure options",
                    systemImage: "gearshape.circle"
                )
            }
        }
    }
}

// Setting categories
enum SettingCategory: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case general = "General"
    case notifications = "Notifications"
    case network = "Network"
    case appearance = "Appearance"
    case privacy = "Privacy"
    case about = "About"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .profile: return "person.circle.fill"
        case .general: return "gearshape"
        case .notifications: return "bell.badge"
        case .network: return "network"
        case .appearance: return "paintbrush"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .profile: return .cyan
        case .general: return .blue
        case .notifications: return .indigo
        case .network: return .green
        case .appearance: return .purple
        case .privacy: return .orange
        case .about: return .gray
        }
    }

    var title: String { rawValue }

    var description: String {
        switch self {
        case .profile: return "Manage your profile and switch accounts"
        case .general: return "General application settings"
        case .notifications: return "Manage notification preferences"
        case .network: return "Configure network and server connections"
        case .appearance: return "Customize the app's appearance"
        case .privacy: return "Privacy and security settings"
        case .about: return "About VibeCare and version information"
        }
    }
}

// Individual setting detail views
struct ProfileSettingsDetail: View {
    @EnvironmentObject private var appState: AppState
    @State private var profileName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Profile Management")
                .font(.headline)

            // Current Profile Section
            if let currentProfile = appState.currentProfile {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Current Profile")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Image(systemName: "person.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.cyan)

                        VStack(alignment: .leading, spacing: 4) {
                            EditableTitle(
                                text: $profileName,
                                placeholder: "Profile name"
                            ) { newName in
                                var updatedProfile = currentProfile
                                updatedProfile.name = newName
                                appState.updateProfile(updatedProfile)
                            }
                            .font(.title3)
                            .fontWeight(.semibold)

                            if let email = currentProfile.email, !email.isEmpty {
                                Text(email)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("ID: \(currentProfile.id)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospaced()
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .onAppear {
                    profileName = currentProfile.name
                }
                .onChange(of: appState.currentProfile?.name) { _, newName in
                    if let newName = newName {
                        profileName = newName
                    }
                }
            }

            Divider()

            // Available Profiles
            VStack(alignment: .leading, spacing: 12) {
                Text("Available Profiles")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if appState.profiles.isEmpty {
                    Text("No profiles available")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(appState.profiles, id: \.id) { profile in
                        HStack {
                            Image(systemName: profile.id == appState.currentProfile?.id ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(profile.id == appState.currentProfile?.id ? .cyan : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.body)
                                if let email = profile.email, !email.isEmpty {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if profile.id != appState.currentProfile?.id {
                                Button("Switch") {
                                    appState.selectProfile(profile)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            profile.id == appState.currentProfile?.id
                                ? Color.cyan.opacity(0.1)
                                : Color.clear
                        )
                        .cornerRadius(8)
                    }
                }
            }

            Divider()

            // Actions
            Button(action: {
                appState.showProfileSelector = true
            }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Create New Profile")
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct GeneralSettingsDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General Settings")
                .font(.headline)

            // Add general settings controls here
            Text("General settings will be configured here")
                .foregroundColor(.secondary)
        }
    }
}

struct NetworkSettingsDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Settings")
                .font(.headline)

            // Add network settings controls here
            Text("Network settings will be configured here")
                .foregroundColor(.secondary)
        }
    }
}

struct AppearanceSettingsDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance Settings")
                .font(.headline)

            // Add appearance settings controls here
            Text("Appearance settings will be configured here")
                .foregroundColor(.secondary)
        }
    }
}

struct PrivacySettingsDetail: View {
    @State private var telemetryEnabled = OTELManager.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Privacy & Data")
                .font(.headline)

            // Telemetry Toggle
            Toggle(isOn: $telemetryEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Telemetry")
                        .font(.body)
                    Text("Send anonymous usage data to help improve VibeCare")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: telemetryEnabled) { _, newValue in
                if newValue {
                    OTELManager.shared.enable()
                } else {
                    OTELManager.shared.disable()
                }
            }

            Divider()

            // Privacy Info
            VStack(alignment: .leading, spacing: 8) {
                Text("Data Collection")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("When telemetry is enabled, we collect:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Label("View navigation patterns", systemImage: "arrow.triangle.branch")
                    Label("Performance metrics", systemImage: "speedometer")
                    Label("Error reports", systemImage: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 8)

                Text("We never collect personal information, schedule data, or routine details.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
                    .padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
    }
}

struct NotificationsSettingsDetail: View {
    @StateObject private var notificationPolicy = NotificationPolicy.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Notification Preferences")
                .font(.headline)

            // Main toggle
            Toggle(isOn: $notificationPolicy.enabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Notifications")
                        .font(.body)
                    Text("Show schedule and routine notifications")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.vertical, 8)

            // Status indicator
            HStack {
                Circle()
                    .fill(notificationPolicy.enabled ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(notificationPolicy.enabled ? "Notifications Active" : "Notifications Paused")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Future features
            Text("Advanced Features")
                .font(.headline)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(
                    icon: "moon.fill",
                    title: "Quiet Hours",
                    description: "Automatically pause notifications during specific times",
                    isComingSoon: true
                )

                FeatureRow(
                    icon: "video.fill",
                    title: "Meeting Detection",
                    description: "Pause notifications when you're in a meeting",
                    isComingSoon: true
                )

                FeatureRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Sharing Detection",
                    description: "Pause notifications when sharing your screen",
                    isComingSoon: true
                )

                FeatureRow(
                    icon: "moon.stars.fill",
                    title: "Focus Mode",
                    description: "Respect system Focus/Do Not Disturb status",
                    isComingSoon: true
                )
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    let isComingSoon: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.body)
                    if isComingSoon {
                        Text("Coming Soon")
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .opacity(isComingSoon ? 0.6 : 1.0)
    }
}

struct AboutSettingsDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About VibeCare")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                DetailRow(title: "Version", value: "1.0.0")
                DetailRow(title: "Build", value: "1")
                DetailRow(title: "Platform", value: "macOS")
            }
        }
    }
}

#Preview {
    SettingsDetailView(selectedSetting: .general)
}