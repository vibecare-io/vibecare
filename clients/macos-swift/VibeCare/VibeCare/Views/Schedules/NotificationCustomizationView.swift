import SVGView
import SwiftUI
import UniformTypeIdentifiers

struct NotificationCustomizationView: View {
  @Binding var preferences: NotificationPreferences
  let scheduleName: String
  let scheduleNotes: String
  @State private var showingFilePicker = false
  @State private var showingIconPicker = false
  @State private var previewNotification = false
  @State private var iconPreviewData: Data?
  @State private var iconPreviewLoading = false
  @State private var iconPreviewError: Error?
  @StateObject private var iconManager = SVGIconManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      // Header with reset button
      HStack {
        Text("Notification Customization")
          .font(.headline)
          .fontWeight(.semibold)

        Spacer()

        Button("Reset to Default") {
          preferences = .default
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
      }

      // Preset Selector
      presetSection

      // SVG Icon Section
      svgIconSection

      // Message Customization
      messageCustomizationSection

      // Position Section
      positionSection

      // Size Controls
      sizeSection

      // Behavior Options
      behaviorSection

      // Preview Button
      previewSection
    }
    .padding(16)
    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    .cornerRadius(12)
    .task {
      // Load icons from backend if not already loaded
      if !iconManager.isLoaded && iconManager.loadError == nil {
        try? await iconManager.loadIcons()
      }
    }
  }

  // MARK: - Preset Section
  private var presetSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Quick Presets")
        .font(.subheadline)
        .fontWeight(.medium)

      HStack(spacing: 12) {
        ForEach(NotificationPreferences.presetNames, id: \.self) { presetName in
          Button(action: {
            if let preset = NotificationPreferences.presets[presetName] {
              preferences = preset
            }
          }) {
            Text(presetName)
              .font(.subheadline)
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Color(NSColor.controlBackgroundColor))
              .cornerRadius(8)
          }
          .buttonStyle(.plain)
        }
        Spacer()
      }
    }
  }

  // MARK: - SVG Icon Section
  private var svgIconSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Icon")
        .font(.subheadline)
        .fontWeight(.medium)

      // Show selected icon preview
      if preferences.hasSVGIcon {
        HStack(spacing: 12) {
          // Icon preview card
          HStack(spacing: 12) {
            // Small icon preview image
            Group {
              if let data = iconPreviewData {
                // Render SVG from loaded data
                SVGView(data: data)
                  .frame(width: 40, height: 40)
              } else if iconPreviewLoading {
                // Show loading indicator
                ProgressView()
                  .scaleEffect(0.5)
                  .frame(width: 40, height: 40)
              } else if iconPreviewError != nil {
                // Show error icon
                Image(systemName: "exclamationmark.triangle")
                  .font(.title3)
                  .foregroundColor(.orange)
                  .frame(width: 40, height: 40)
              } else {
                // Show placeholder
                Image(systemName: "photo")
                  .font(.title2)
                  .foregroundColor(.secondary)
                  .frame(width: 40, height: 40)
              }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .task(id: preferences.svgPath) {
              // Load SVG data when icon URL changes
              await loadIconPreview()
            }

            // Icon info
            if let iconId = preferences.extractedIconId,
              let icon = iconManager.icon(withId: iconId)
            {
              // Bundled icon preview (from backend URL)
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                  Text(icon.name)
                    .font(.caption)
                    .fontWeight(.medium)
                }
                Text(icon.category.displayName)
                  .font(.caption2)
                  .foregroundColor(.secondary)
              }
            } else if let svgPath = preferences.svgPath {
              // Custom SVG file path preview
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Image(systemName: "doc.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
                  Text("Custom SVG")
                    .font(.caption)
                    .fontWeight(.medium)
                }
                Text(URL(fileURLWithPath: svgPath).lastPathComponent)
                  .font(.caption2)
                  .foregroundColor(.secondary)
                  .lineLimit(1)
              }
            }

            Spacer()

            // Size controls
            HStack(spacing: 8) {
              Text("Size:")
                .font(.caption)
                .foregroundColor(.secondary)

              TextField(
                "Width",
                value: Binding(
                  get: { Double(preferences.svgWidth ?? 350) },
                  set: { preferences.svgWidth = CGFloat($0) }
                ), format: .number
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 70)

              Text("×")
                .foregroundColor(.secondary)

              TextField(
                "Height",
                value: Binding(
                  get: { Double(preferences.svgHeight ?? 320) },
                  set: { preferences.svgHeight = CGFloat($0) }
                ), format: .number
              )
              .textFieldStyle(.roundedBorder)
              .frame(width: 70)
            }
          }
          .padding(12)
          .background(Color(NSColor.controlBackgroundColor))
          .cornerRadius(8)

          // Remove button
          Button("Remove") {
            preferences.svgPath = nil
            preferences.svgWidth = nil
            preferences.svgHeight = nil
          }
          .buttonStyle(.plain)
          .foregroundColor(.red)
        }
      } else {
        // No icon selected - show selection buttons
        HStack(spacing: 12) {
          // Browse bundled icons button
          Button(action: {
            showingIconPicker = true
          }) {
            HStack {
              Image(systemName: "square.grid.3x3.fill")
                .foregroundColor(.secondary)
              Text("Browse Icons")
                .foregroundColor(.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
          }
          .buttonStyle(.plain)
          .popover(isPresented: $showingIconPicker) {
            SVGIconPickerView(
              iconManager: iconManager,
              selectedIconId: Binding(
                get: { preferences.extractedIconId },
                set: { _ in /* Icon ID extracted from URL, no direct set */ }
              ),
              onSelect: { icon in
                // Build full backend URL for bundled icon
                let iconURL = NetworkConfiguration.buildIconURL(iconId: icon.id)

                // Create mutable copy, modify, then assign back
                var updated = preferences
                updated.svgPath = iconURL
                updated.svgWidth = updated.svgWidth ?? 350
                updated.svgHeight = updated.svgHeight ?? 320
                preferences = updated

                showingIconPicker = false
              },
              onDismiss: {
                showingIconPicker = false
              }
            )
          }

          // Custom SVG file button
          Button(action: {
            showingFilePicker = true
          }) {
            HStack {
              Image(systemName: "doc.badge.plus")
                .foregroundColor(.secondary)
              Text("Custom SVG")
                .foregroundColor(.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
          }
          .buttonStyle(.plain)
        }
      }

      Text("💡 Choose from \(iconManager.icons.count) bundled icons or use your own custom SVG")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.svg],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        if let url = urls.first {
          preferences.bundledIconId = nil  // Clear bundled icon
          preferences.svgPath = url.path
          preferences.svgWidth = preferences.svgWidth ?? 350
          preferences.svgHeight = preferences.svgHeight ?? 320
        }
      case .failure(let error):
        print("Error selecting SVG: \(error)")
      }
    }
  }

  // MARK: - Message Customization Section
  private var messageCustomizationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Message Template")
        .font(.subheadline)
        .fontWeight(.medium)

      VStack(alignment: .leading, spacing: 8) {
        TextField(
          "Title (optional)",
          text: Binding(
            get: { preferences.title ?? "" },
            set: { preferences.title = $0.isEmpty ? nil : $0 }
          )
        )
        .textFieldStyle(.roundedBorder)

        TextEditor(
          text: Binding(
            get: { preferences.message ?? "" },
            set: { preferences.message = $0.isEmpty ? nil : $0 }
          )
        )
        .font(.body)
        .frame(height: 80)
        .padding(4)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
      }

      Text("Available variables: {scheduleName}, {routineName}, {time}")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.leading, 4)
    }
  }

  // MARK: - Position Section
  private var positionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Position")
        .font(.subheadline)
        .fontWeight(.medium)

      HStack(spacing: 12) {
        ForEach(NotificationPosition.allCases, id: \.self) { position in
          Button(action: {
            preferences.position = position
          }) {
            VStack(spacing: 4) {
              Image(systemName: position.iconName)
                .font(.title3)
              Text(position.displayName)
                .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
              preferences.position == position
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(
              preferences.position == position
                ? .white
                : .primary
            )
            .cornerRadius(8)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - Size Section
  private var sizeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Notification Size")
        .font(.subheadline)
        .fontWeight(.medium)

      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Width")
            .font(.caption)
            .foregroundColor(.secondary)

          HStack {
            Slider(
              value: Binding(
                get: { preferences.width ?? 450 },
                set: { preferences.width = $0 }
              ),
              in: 300...800,
              step: 50
            )

            Text("\(Int(preferences.width ?? 450))")
              .font(.caption)
              .foregroundColor(.secondary)
              .frame(width: 40, alignment: .trailing)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Height")
            .font(.caption)
            .foregroundColor(.secondary)

          HStack {
            Slider(
              value: Binding(
                get: { preferences.height ?? 220 },
                set: { preferences.height = $0 }
              ),
              in: 150...500,
              step: 25
            )

            Text("\(Int(preferences.height ?? 220))")
              .font(.caption)
              .foregroundColor(.secondary)
              .frame(width: 40, alignment: .trailing)
          }
        }
      }
    }
  }

  // MARK: - Behavior Section
  private var behaviorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Behavior")
        .font(.subheadline)
        .fontWeight(.medium)

      Toggle("Allow moving notification", isOn: $preferences.moveable)
        .toggleStyle(.switch)

      Toggle("Enable screen blur", isOn: $preferences.screenBlurEnabled)
        .toggleStyle(.switch)

      // Blur intensity picker (shown when blur is enabled)
      if preferences.screenBlurEnabled {
        VStack(alignment: .leading, spacing: 4) {
          Text("Blur Intensity")
            .font(.caption)
            .foregroundColor(.secondary)

          HStack(spacing: 12) {
            ForEach(BlurIntensity.allCases, id: \.self) { intensity in
              Button(action: {
                preferences.screenBlurIntensity = intensity
              }) {
                VStack(spacing: 4) {
                  Image(systemName: intensity.iconName)
                    .font(.title3)
                  Text(intensity.displayName)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                  preferences.screenBlurIntensity == intensity
                    ? Color.accentColor
                    : Color(NSColor.controlBackgroundColor)
                )
                .foregroundColor(
                  preferences.screenBlurIntensity == intensity
                    ? .white
                    : .primary
                )
                .cornerRadius(8)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      // Auto-dismiss duration
      VStack(alignment: .leading, spacing: 4) {
        Text("Auto-dismiss after (seconds)")
          .font(.caption)
          .foregroundColor(.secondary)

        HStack {
          Slider(
            value: Binding(
              get: { preferences.autoDismissAfter ?? 20.0 },
              set: { preferences.autoDismissAfter = $0 }
            ),
            in: 5...60,
            step: 5
          )

          Text("\(Int(preferences.autoDismissAfter ?? 20))s")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
        }
      }
    }
  }

  // MARK: - Preview Section
  private var previewSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: {
        showPreviewNotification()
      }) {
        HStack {
          Image(systemName: "eye")
          Text("Preview Notification")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.2))
        .foregroundColor(.accentColor)
        .cornerRadius(8)
      }
      .buttonStyle(.plain)

      if previewNotification {
        Text("Preview sent!")
          .font(.caption)
          .foregroundColor(.green)
          .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
              previewNotification = false
            }
          }
      }
    }
  }

  // MARK: - Helper Methods

  private func loadIconPreview() async {
    // Reset state
    iconPreviewData = nil
    iconPreviewError = nil

    guard let svgPath = preferences.svgPath,
      let iconURL = URL(string: svgPath)
    else {
      return
    }

    // Only fetch if it's an HTTP URL (bundled icon from backend)
    guard iconURL.scheme == "http" || iconURL.scheme == "https" else {
      // For local files, we'd need file access - skip for now
      return
    }

    iconPreviewLoading = true

    do {
      let (data, _) = try await URLSession.shared.data(from: iconURL)
      await MainActor.run {
        self.iconPreviewData = data
        self.iconPreviewLoading = false
      }
    } catch {
      await MainActor.run {
        self.iconPreviewError = error
        self.iconPreviewLoading = false
      }
    }
  }

  private func showPreviewNotification() {
    // Build preview message showing selected options
    var optionsInfo = "Testing notification with:\n"

    if let svgPath = preferences.svgPath {
      optionsInfo += "• SVG: \(URL(fileURLWithPath: svgPath).lastPathComponent)\n"
      if let width = preferences.svgWidth, let height = preferences.svgHeight {
        optionsInfo += "• SVG Size: \(Int(width))×\(Int(height))\n"
      }
    } else {
      optionsInfo += "• Icon: System bell icon\n"
    }

    optionsInfo += "• Position: \(preferences.position.displayName)\n"

    if let width = preferences.width, let height = preferences.height {
      optionsInfo += "• Notification Size: \(Int(width))×\(Int(height))\n"
    }

    optionsInfo += "• Moveable: \(preferences.moveable ? "Yes" : "No")\n"
    if preferences.screenBlurEnabled {
      optionsInfo += "• Screen Blur: \(preferences.screenBlurIntensity.displayName)\n"
    } else {
      optionsInfo += "• Screen Blur: Disabled\n"
    }

    if let dismissAfter = preferences.autoDismissAfter {
      optionsInfo += "• Auto-dismiss: \(Int(dismissAfter))s\n"
    }

    if let customTitle = preferences.title, !customTitle.isEmpty {
      optionsInfo += "• Custom Title: \(customTitle)\n"
    }

    if let customMessage = preferences.message, !customMessage.isEmpty {
      optionsInfo += "• Custom Message: \(customMessage)\n"
    }

    // Show actual notification using VibeNotify with current preferences
    // Use a copy of preferences with the options info in the message for preview
    var previewPrefs = preferences
    if previewPrefs.message == nil || previewPrefs.message?.isEmpty == true {
      previewPrefs.message = optionsInfo
    }

    _ = VibeNotifyConfig.showScheduleNotification(
      scheduleName: scheduleName.isEmpty ? "Preview Schedule" : scheduleName,
      routineName: "Preview Routine",
      scheduledTime: Date(),
      notes: scheduleNotes.isEmpty ? nil : scheduleNotes,
      preferences: previewPrefs
    )

    // Show feedback message
    previewNotification = true
  }
}

// MARK: - SVG UTType Extension
extension UTType {
  static var svg: UTType {
    UTType(filenameExtension: "svg") ?? .data
  }
}

// MARK: - Preview
#Preview {
  NotificationCustomizationView(
    preferences: .constant(.default),
    scheduleName: "Every 20 minutes",
    scheduleNotes: "Preview notes for testing"
  )
  .frame(width: 650)
  .padding()
}
