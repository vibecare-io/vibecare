import SwiftUI

/// The global notification appearance editor — the one place the user sets how
/// notifications look, instead of repeating it on every action.
///
/// Every control here writes `GlobalNotificationSettings`, which is the bottom
/// of the resolution stack: an action that says nothing about its appearance
/// gets exactly this, and an action that overrides one key keeps that key and
/// inherits the rest. The per-action editor's Advanced disclosure is the other
/// half of the story.
struct NotificationAppearanceSettingsView: View {
  @EnvironmentObject private var appState: AppState

  @State private var settings: GlobalNotificationSettings = .current
  @State private var previewSent = false
  /// Coalesces a slider drag into one profile write. The local mirror is
  /// updated on every change (so the preview button is always honest); only the
  /// gRPC round trip waits.
  @State private var syncTask: Task<Void, Never>?

  private static let profileSyncDelay: Duration = .milliseconds(700)

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Appearance")
        .font(.headline)

      Text("Every notification uses these unless the action that fires it overrides them.")
        .font(.caption)
        .foregroundColor(.secondary)

      positionSection

      Divider()

      sizeSection

      Divider()

      screenBlurSection

      Divider()

      screenDimSection

      Divider()

      behaviorSection

      Divider()

      breakCountdownSection

      Divider()

      previewSection
    }
    .onChange(of: settings) { _, newValue in
      scheduleSave(newValue)
    }
    .onAppear {
      settings = .current
    }
  }

  // MARK: - Position

  private var positionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Position")
        .font(.subheadline)
        .foregroundColor(.secondary)

      HStack(spacing: 12) {
        ForEach(NotificationPosition.allCases, id: \.self) { position in
          SelectableTile(
            iconName: position.iconName,
            label: position.displayName,
            isSelected: settings.position == position
          ) {
            settings.position = position
          }
        }
      }

      Text("Full-screen alerts — screen blur, or an action with a break countdown — always cover the whole display, so position applies to the smaller floating alerts.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Size

  private var sizeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Size")
        .font(.subheadline)
        .foregroundColor(.secondary)

      LabeledSlider(
        title: "Width",
        value: Binding(get: { Double(settings.width) }, set: { settings.width = CGFloat($0) }),
        range: 300...800,
        step: 50,
        valueLabel: "\(Int(settings.width))"
      )

      LabeledSlider(
        title: "Height",
        value: Binding(get: { Double(settings.height) }, set: { settings.height = CGFloat($0) }),
        range: 150...500,
        step: 25,
        valueLabel: "\(Int(settings.height))"
      )

      Text("Height is a floor: an alert grows past it when its illustration or message needs the room.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Screen blur

  private var screenBlurSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Screen Blur")
        .font(.subheadline)
        .foregroundColor(.secondary)

      Toggle(isOn: $settings.screenBlurEnabled) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Blur the desktop behind notifications")
            .font(.body)
          Text("Turns a notification into a full-screen interruption instead of a floating alert.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)

      if settings.screenBlurEnabled {
        VStack(alignment: .leading, spacing: 8) {
          Text("Intensity")
            .font(.caption)
            .foregroundColor(.secondary)

          HStack(spacing: 12) {
            ForEach(BlurIntensity.allCases, id: \.self) { intensity in
              SelectableTile(
                iconName: intensity.iconName,
                label: intensity.displayName,
                isSelected: settings.screenBlurIntensity == intensity
              ) {
                settings.screenBlurIntensity = intensity
              }
            }
          }

          Text("Blur controls how much desktop detail survives — not how much light. That's dimming, below.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }

  // MARK: - Screen dim

  private var screenDimSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Screen Dim")
        .font(.subheadline)
        .foregroundColor(.secondary)

      LabeledSlider(
        title: "Darkness behind full-screen alerts",
        value: $settings.screenDim,
        range: GlobalNotificationSettings.screenDimRange,
        step: 0.05,
        valueLabel: "\(Int((settings.screenDim * 100).rounded()))%"
      )

      VStack(alignment: .leading, spacing: 6) {
        Text(
          "Dimming, not blurring, is what makes the text readable. At \(Int((GlobalNotificationSettings.wcagSafeScreenDim * 100).rounded()))% white text clears WCAG AA contrast over any desktop — even a pure white one."
        )
        .font(.caption)
        .foregroundColor(.secondary)

        if settings.screenDim < GlobalNotificationSettings.wcagSafeScreenDim {
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
            Text(
              "Below \(Int((GlobalNotificationSettings.wcagSafeScreenDim * 100).rounded()))% the desktop shows through more, so alerts fall back to drawing their own shading behind the text."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }

          Button("Use the readable minimum") {
            settings.screenDim = GlobalNotificationSettings.wcagSafeScreenDim
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      Text("Only applies to full-screen alerts; a floating alert leaves the desktop's light alone.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Behavior

  private var behaviorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Behavior")
        .font(.subheadline)
        .foregroundColor(.secondary)

      Toggle(isOn: $settings.moveable) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Allow moving the notification")
            .font(.body)
          Text("Drag a floating alert out of the way instead of dismissing it.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)

      LabeledSlider(
        title: "Auto-dismiss after",
        value: $settings.autoDismissAfter,
        range: 5...60,
        step: 5,
        valueLabel: "\(Int(settings.autoDismissAfter))s"
      )

      Text("Ignored while a break countdown is running — the break's own timer owns the alert's lifetime.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Break countdown

  private var breakCountdownSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Break Countdown")
        .font(.subheadline)
        .foregroundColor(.secondary)

      Text("Wording for the big countdown ring an action shows when it sets a break duration.")
        .font(.caption)
        .foregroundColor(.secondary)

      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Unit label")
            .font(.caption)
            .foregroundColor(.secondary)
          TextField("seconds", text: $settings.breakUnitLabel)
            .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Completion label")
            .font(.caption)
            .foregroundColor(.secondary)
          TextField("Break complete", text: $settings.breakCompletionLabel)
            .textFieldStyle(.roundedBorder)
        }
      }
    }
  }

  // MARK: - Preview

  private var previewSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Button {
          showPreview()
        } label: {
          Label("Preview Notification", systemImage: "eye")
        }
        .buttonStyle(.borderedProminent)

        Button("Reset to Defaults") {
          settings = .fallback
        }
        .buttonStyle(.bordered)

        if previewSent {
          HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
              .foregroundColor(.green)
            Text("Preview sent")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .transition(.opacity)
        }

        Spacer()
      }

      Text("Renders through the same path a real schedule notification takes, so what you see is what you'll get.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Actions

  /// The preview goes through `VibeNotifyConfig.showScheduleNotification` —
  /// the same funnel the three per-action preview buttons and every delivered
  /// schedule alert use. A preview rendered any other way would teach a layout
  /// the user is never going to get.
  private func showPreview() {
    // Flush before previewing: the funnel reads the persisted screen dim, and
    // an in-flight slider edit that has not landed yet would preview the old
    // one.
    settings.persistLocally()

    _ = VibeNotifyConfig.showScheduleNotification(
      scheduleName: "Preview Notification",
      routineName: "Global notification settings",
      scheduledTime: Date(),
      notes: nil,
      preferences: settings.basePreferences()
    )

    withAnimation { previewSent = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { previewSent = false }
    }
  }

  private func scheduleSave(_ newValue: GlobalNotificationSettings) {
    newValue.persistLocally()
    syncTask?.cancel()
    syncTask = Task {
      try? await Task.sleep(for: Self.profileSyncDelay)
      guard !Task.isCancelled else { return }
      appState.saveGlobalNotificationSettings(newValue)
    }
  }
}

// MARK: - Shared Controls

/// The icon-over-label tile the per-action position and blur-intensity pickers
/// already use, factored out so both settings surfaces stay identical rather
/// than similar.
struct SelectableTile: View {
  let iconName: String
  let label: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: iconName)
          .font(.title3)
        Text(label)
          .font(.caption)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
      .foregroundColor(isSelected ? .white : .primary)
      .cornerRadius(8)
    }
    .buttonStyle(.plain)
  }
}

/// A slider with the caption label and trailing readout the existing
/// customization sheets use.
struct LabeledSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let valueLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)

      HStack {
        Slider(value: $value, in: range, step: step)

        Text(valueLabel)
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 44, alignment: .trailing)
          .monospacedDigit()
      }
    }
  }
}
