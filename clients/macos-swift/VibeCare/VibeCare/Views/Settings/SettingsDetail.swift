import Logging
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
            case .debug:
              DebugSettingsDetail()
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
  case debug = "Debug"
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
    case .debug: return "ant.circle.fill"
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
    case .debug: return .red
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
    case .debug: return "Debug logging and developer tools"
    case .about: return "About VibeCare and version information"
    }
  }
}

// Individual setting detail views
struct ProfileSettingsDetail: View {
  @EnvironmentObject private var appState: AppState
  @State private var profileName: String = ""
  @State private var showTimezonePicker: Bool = false

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

      // Timezone Section
      if let currentProfile = appState.currentProfile {
        VStack(alignment: .leading, spacing: 12) {
          Text("Timezone")
            .font(.subheadline)
            .foregroundColor(.secondary)

          HStack(spacing: 12) {
            Image(systemName: "globe")
              .font(.title2)
              .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
              Text(currentProfile.timeZoneDisplayName)
                .font(.body)
                .fontWeight(.medium)

              Text(currentProfile.timezone)
                .font(.caption)
                .foregroundColor(.secondary)
                .monospaced()
            }

            Spacer()

            Button("Change") {
              showTimezonePicker = true
            }
            .buttonStyle(.bordered)
          }
          .padding()
          .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
          .cornerRadius(12)
        }
        .sheet(isPresented: $showTimezonePicker) {
          TimezonePickerView(
            selectedTimezone: currentProfile.timezone,
            onSelect: { newTimezone in
              var updatedProfile = currentProfile
              updatedProfile.timezone = newTimezone
              appState.updateProfile(updatedProfile)
              showTimezonePicker = false
            }
          )
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
              Image(
                systemName: profile.id == appState.currentProfile?.id
                  ? "checkmark.circle.fill" : "circle"
              )
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
  @AppStorage("backend.autoReload") private var autoReloadBackend: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("General Settings")
        .font(.headline)

      VStack(alignment: .leading, spacing: 12) {
        Text("Backend")
          .font(.subheadline)
          .foregroundColor(.secondary)

        Toggle(isOn: $autoReloadBackend) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Automatically restart backend after an update")
              .font(.body)
            Text("When the app updates, silently restart the backend instead of prompting.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .toggleStyle(.switch)
      }
    }
  }
}

struct NetworkSettingsDetail: View {
  @State private var grpcURL: String =
    UserDefaults.standard.string(forKey: "grpc_url") ?? "grpc://localhost:50051"
  @State private var backendURL: String =
    UserDefaults.standard.string(forKey: "backend_url") ?? "http://localhost:8080"
  @State private var showSaveSuccess: Bool = false
  @State private var validationError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Server Connection")
        .font(.headline)

      // Connection Status
      HStack {
        Circle()
          .fill(Color.green)
          .frame(width: 8, height: 8)
        Text("Connected to backend")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Divider()

      // gRPC URL Configuration
      VStack(alignment: .leading, spacing: 8) {
        Text("gRPC URL")
          .font(.subheadline)
          .fontWeight(.semibold)
        TextField("grpc://localhost:50051", text: $grpcURL)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Full gRPC service URL (scheme://host:port)")
            .font(.caption)
            .foregroundColor(.secondary)
          Text("Examples: grpc://localhost:50051 or grpcs://api.example.com:443")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }

      // Backend URL Configuration
      VStack(alignment: .leading, spacing: 8) {
        Text("Backend URL")
          .font(.subheadline)
          .fontWeight(.semibold)
        TextField("http://localhost:8080", text: $backendURL)
          .textFieldStyle(.roundedBorder)
          .disableAutocorrection(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Full HTTP backend URL for icons and web services")
            .font(.caption)
            .foregroundColor(.secondary)
          Text("Examples: http://localhost:8080 or https://api.example.com")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      }

      // Validation Error
      if let error = validationError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
          Text(error)
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.vertical, 8)
      }

      Divider()

      // Save Button
      HStack {
        Button(action: saveSettings) {
          HStack {
            Image(systemName: "checkmark.circle.fill")
            Text("Save Settings")
          }
        }
        .buttonStyle(.borderedProminent)

        if showSaveSuccess {
          HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
            Text("Saved")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .transition(.opacity)
        }

        Spacer()

        Button(action: resetToDefaults) {
          Text("Reset to Defaults")
        }
        .buttonStyle(.bordered)
      }

      Divider()

      // Info Box
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "info.circle.fill")
            .foregroundColor(.blue)
          Text("Connection Information")
            .font(.subheadline)
            .fontWeight(.semibold)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("• gRPC service: \(grpcURL)")
          Text("• Backend server: \(backendURL)")
          Text("• Icon URLs: \(backendURL)/api/icons/{id}.svg")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, 8)
      }
      .padding()
      .background(Color.blue.opacity(0.05))
      .cornerRadius(8)
    }
  }

  private func saveSettings() {
    // Validate URLs
    guard URL(string: grpcURL) != nil else {
      validationError = "Invalid gRPC URL format"
      return
    }

    guard URL(string: backendURL) != nil else {
      validationError = "Invalid backend URL format"
      return
    }

    validationError = nil

    // Save URLs to UserDefaults
    UserDefaults.standard.set(grpcURL, forKey: "grpc_url")
    UserDefaults.standard.set(backendURL, forKey: "backend_url")

    // Parse gRPC URL and update GRPCClientManager
    if let components = NetworkConfiguration.parseGRPCURL(grpcURL) {
      GRPCClientManager.shared.updateConnectionSettings(
        host: components.host,
        port: components.port,
        webPort: 0,  // Not used anymore but keep for backward compat
        useTLS: components.useTLS
      )
    }

    withAnimation {
      showSaveSuccess = true
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation {
        showSaveSuccess = false
      }
    }
  }

  private func resetToDefaults() {
    grpcURL = "grpc://localhost:50051"
    backendURL = "http://localhost:8080"
    validationError = nil
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

      // Global appearance — the defaults every notification inherits.
      NotificationAppearanceSettingsView()

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

struct DebugSettingsDetail: View {
  @StateObject private var debugSettings = DebugSettings.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Log Level Section
      VStack(alignment: .leading, spacing: 12) {
        Text("Log Level")
          .font(.headline)

        Picker("Log Level", selection: $debugSettings.currentLogLevel) {
          Text("Trace (Most Verbose)").tag(Logger.Level.trace)
          Text("Debug").tag(Logger.Level.debug)
          Text("Info").tag(Logger.Level.info)
          Text("Notice").tag(Logger.Level.notice)
          Text("Warning").tag(Logger.Level.warning)
          Text("Error").tag(Logger.Level.error)
          Text("Critical (Least Verbose)").tag(Logger.Level.critical)
        }
        .pickerStyle(.menu)
        .help("Control which log messages are shown in Console.app")

        Text("Current level: **\(debugSettings.currentLogLevel.rawValue.uppercased())**")
          .font(.caption)
          .foregroundColor(.secondary)

        Text(
          "Debug logs include icon loading, notification preview, and data flow. Useful for troubleshooting."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }

      Divider()

      // Log Collection Section
      VStack(alignment: .leading, spacing: 12) {
        Text("Log Collection")
          .font(.headline)

        Toggle("Collect logs for in-app viewer", isOn: $debugSettings.collectLogsEnabled)
          .help("Store recent logs in memory for viewing within the app (future feature)")

        if debugSettings.collectLogsEnabled {
          HStack {
            Image(systemName: "info.circle")
              .foregroundColor(.blue)
            Text("Logs are stored in memory. Maximum 1000 entries.")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Button("Clear Collected Logs") {
            Task {
              await LogCollector.shared.clear()
            }
          }
          .buttonStyle(.bordered)
        }
      }

      Divider()

      // Info Section
      VStack(alignment: .leading, spacing: 8) {
        Text("About Debug Logging")
          .font(.headline)

        VStack(alignment: .leading, spacing: 4) {
          Text("• **Trace**: All messages (very verbose)")
          Text("• **Debug**: Debug information including 🔍 icon logs")
          Text("• **Info**: General information (recommended for development)")
          Text("• **Notice**: Important information (recommended for production)")
          Text("• **Warning**: Warning messages")
          Text("• **Error**: Error messages only")
          Text("• **Critical**: Critical errors only")
        }
        .font(.caption)
        .foregroundColor(.secondary)

        Text("View logs in Console.app or use the in-app log viewer (coming soon).")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.top, 8)
      }

      Spacer()
    }
  }
}

struct AboutSettingsDetail: View {
  enum CheckState: Equatable {
    case idle, checking, upToDate, available(String), failed
  }

  @StateObject private var backend = BackendManager.shared
  @State private var checkState: CheckState = .idle

  private var installedVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Client (app UI) version comes from the bundle; Backend (server) version
      // comes from /version. On a shipped build both are the same release tag;
      // in a dev build the client shows "1.0" (Xcode default) while the backend
      // still reports the real running tag.
      VStack(alignment: .leading, spacing: 8) {
        DetailRow(title: "Client (app)", value: installedVersion)
        DetailRow(title: "Backend (server)", value: backend.backendVersion ?? "not connected")
        DetailRow(title: "Platform", value: "macOS")
      }

      // Update check
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Button {
            Task { await checkForUpdates() }
          } label: {
            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(checkState == .checking)
          if checkState == .checking {
            ProgressView().controlSize(.small)
          }
        }
        updateStatus
        Text("After running `brew upgrade`, quit and reopen VibeCare to apply the update.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.top, 4)

      Divider()

      // Website
      Text("Website")
        .font(.headline)

      AboutView()
        .frame(minHeight: 800)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .task { await backend.refreshVersion() }
  }

  @ViewBuilder private var updateStatus: some View {
    switch checkState {
    case .idle, .checking:
      EmptyView()
    case .upToDate:
      Label("You're on the latest version.", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundColor(.green)
    case .available(let latest):
      VStack(alignment: .leading, spacing: 6) {
        Label("Update available: \(latest)", systemImage: "arrow.down.circle.fill")
          .font(.caption)
          .foregroundColor(.blue)
        HStack(spacing: 6) {
          Text("brew upgrade --cask vibecare")
            .font(.system(.caption, design: .monospaced))
            .padding(6)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew upgrade --cask vibecare", forType: .string)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy command")
        }
      }
    case .failed:
      Label("Couldn't check for updates. Try again later.", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundColor(.orange)
    }
  }

  private func checkForUpdates() async {
    checkState = .checking
    guard let latest = await UpdateChecker.latestVersion() else {
      checkState = .failed
      return
    }
    checkState = UpdateChecker.isUpdateAvailable(installed: installedVersion, latest: latest)
      ? .available(latest)
      : .upToDate
  }
}

#Preview {
  SettingsDetailView(selectedSetting: .general)
}
