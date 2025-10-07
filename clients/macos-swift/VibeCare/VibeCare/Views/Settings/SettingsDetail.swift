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
    case general = "General"
    case notifications = "Notifications"
    case network = "Network"
    case appearance = "Appearance"
    case privacy = "Privacy"
    case about = "About"

    var id: String { rawValue }

    var iconName: String {
        switch self {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy Settings")
                .font(.headline)

            // Add privacy settings controls here
            Text("Privacy settings will be configured here")
                .foregroundColor(.secondary)
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