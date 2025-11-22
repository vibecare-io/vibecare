import SwiftUI
import UniformTypeIdentifiers

// MARK: - ScheduleActionCard Model
struct ScheduleActionCard: Identifiable, Equatable {
    let id: String
    var type: ActionType
    var parameters: [String: String]
    var notificationPreferences: NotificationPreferences = .default // For notification actions

    static func == (lhs: ScheduleActionCard, rhs: ScheduleActionCard) -> Bool {
        return lhs.id == rhs.id &&
               lhs.type == rhs.type &&
               lhs.parameters == rhs.parameters &&
               lhs.notificationPreferences == rhs.notificationPreferences
    }

    init(id: String = UUID().uuidString, type: ActionType, parameters: [String: String] = [:]) {
        self.id = id
        self.type = type

        print("DEBUG [ScheduleActionCard.init]: Creating card with id=\(id), type=\(type)")
        print("DEBUG [ScheduleActionCard.init]: Input parameters count=\(parameters.count), keys=\(parameters.keys.sorted())")

        // Initialize notification preferences for notification type
        if type == .notification {
            // For new notification actions, initialize with default parameters
            if parameters.isEmpty {
                print("DEBUG [ScheduleActionCard.init]: New notification action - initializing with default title/body")
                self.parameters = [
                    "title": "",
                    "body": ""
                ]
                self.notificationPreferences = .default
            } else {
                // Loading existing action - deserialize from parameters
                print("DEBUG [ScheduleActionCard.init]: Loading existing notification action from parameters")
                self.parameters = parameters
                let deserialized = Self.deserializeNotificationPreferences(from: parameters)
                print("DEBUG [ScheduleActionCard.init]: Deserialized notification prefs: \(deserialized != nil ? "present" : "nil")")
                self.notificationPreferences = deserialized ?? .default

                print("DEBUG [ScheduleActionCard.init]: Final prefs: title=\(notificationPreferences.title ?? "nil"), position=\(notificationPreferences.position)")
            }
        } else {
            self.parameters = parameters
            // notificationPreferences already has .default value
        }
    }

    func toAction(profileId: String, scheduleName: String? = nil, scheduleNotes: String? = nil, routineName: String? = nil) -> Action {
        var actionParams = parameters

        // Serialize notification preferences into parameters for notification actions
        if type == .notification {
            actionParams = Self.serializeNotificationPreferences(notificationPreferences, into: actionParams)

            // Apply defaults for empty title/body
            if actionParams["title"]?.isEmpty ?? true {
                actionParams["title"] = scheduleName ?? routineName ?? "Reminder"
            }

            if actionParams["body"]?.isEmpty ?? true {
                actionParams["body"] = scheduleNotes ?? ""
            }
        }

        return Action(
            id: id,
            profileId: profileId,
            type: type,
            name: generateName(scheduleName: scheduleName, routineName: routineName),
            description: "",
            parameters: actionParams
        )
    }

    private func generateName(scheduleName: String? = nil, routineName: String? = nil) -> String {
        switch type {
        case .notification:
            // Check preferences first
            if let title = notificationPreferences.title, !title.isEmpty {
                return title
            }
            // Then check parameters
            if let title = parameters["title"], !title.isEmpty {
                return title
            }
            // Use schedule name, then routine name as fallback
            return scheduleName ?? routineName ?? "Notification"

        case .openLink:
            if let url = parameters["url"], !url.isEmpty {
                return url
            }
            return "Open Link"

        case .sendEmail:
            if let subject = parameters["subject"], !subject.isEmpty {
                return subject
            }
            return "Send Email"

        case .runScript:
            if let script = parameters["script"], !script.isEmpty {
                return script
            }
            return "Run Script"

        case .playSound:
            if let sound = parameters["sound_file"], !sound.isEmpty {
                return sound
            }
            return "Play Sound"

        case .systemCommand:
            if let command = parameters["command"], !command.isEmpty {
                return command
            }
            return "System Command"

        case .apiCall:
            if let url = parameters["url"], !url.isEmpty {
                return url
            }
            return "API Call"

        case .logEntry:
            if let message = parameters["message"], !message.isEmpty {
                return message
            }
            return "Log Entry"
        }
    }

    // MARK: - Notification Preferences Serialization

    private static func serializeNotificationPreferences(_ prefs: NotificationPreferences, into params: [String: String]) -> [String: String] {
        var result = params  // Start with existing params to preserve title/body from UI

        // Serialize SVG path (works for both bundled URLs and custom file paths)
        if let svgPath = prefs.svgPath {
            result["svg_path"] = svgPath
            // Remove old bundled_id parameter if it exists (for migration)
            result.removeValue(forKey: "svg_bundled_id")
        } else {
            // No icon selected - clear both parameters
            result.removeValue(forKey: "svg_path")
            result.removeValue(forKey: "svg_bundled_id")
        }

        if let svgWidth = prefs.svgWidth {
            result["svg_width"] = String(Double(svgWidth))
        }
        if let svgHeight = prefs.svgHeight {
            result["svg_height"] = String(Double(svgHeight))
        }

        // Only override title/body if explicitly set in preferences
        if let title = prefs.title, !title.isEmpty {
            result["title"] = title
        }
        if let message = prefs.message, !message.isEmpty {
            result["body"] = message
        }

        // Ensure required fields exist (even if empty)
        if result["title"] == nil {
            result["title"] = ""
        }
        if result["body"] == nil {
            result["body"] = ""
        }

        result["position"] = prefs.position.rawValue
        if let width = prefs.width {
            result["width"] = String(Double(width))
        }
        if let height = prefs.height {
            result["height"] = String(Double(height))
        }
        result["moveable"] = String(prefs.moveable)
        if let autoDismiss = prefs.autoDismissAfter {
            result["auto_dismiss_after"] = String(autoDismiss)
        }
        result["screen_blur_enabled"] = String(prefs.screenBlurEnabled)

        return result
    }

    private static func deserializeNotificationPreferences(from params: [String: String]) -> NotificationPreferences? {
        // Create notification preferences from parameters
        // Only read svg_path (contains full URL for both bundled and custom icons)
        let svgPath = params["svg_path"]
        let svgWidth = params["svg_width"].flatMap { Double($0) }.map { CGFloat($0) }
        let svgHeight = params["svg_height"].flatMap { Double($0) }.map { CGFloat($0) }
        let title = params["title"]
        let message = params["body"]
        let position = params["position"].flatMap { NotificationPosition(rawValue: $0) } ?? .center
        let width = params["width"].flatMap { Double($0) }.map { CGFloat($0) }
        let height = params["height"].flatMap { Double($0) }.map { CGFloat($0) }
        let moveable = params["moveable"].flatMap { Bool($0) } ?? true
        let autoDismissAfter = params["auto_dismiss_after"].flatMap { Double($0) }
        let screenBlurEnabled = params["screen_blur_enabled"].flatMap { Bool($0) } ?? false

        return NotificationPreferences(
            bundledIconId: nil, // Always nil now - IDs converted to URLs
            svgPath: svgPath,
            svgWidth: svgWidth,
            svgHeight: svgHeight,
            title: title,
            message: message,
            position: position,
            width: width,
            height: height,
            moveable: moveable,
            autoDismissAfter: autoDismissAfter,
            screenBlurEnabled: screenBlurEnabled
        )
    }
}

// MARK: - ScheduleActionCardView
struct ScheduleActionCardView: View {
    @Binding var card: ScheduleActionCard
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: card.type.iconName)
                    .font(.title3)
                    .foregroundColor(colorForType(card.type))

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.type.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text(card.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Parameters
            if card.type == .notification {
                NotificationActionParametersView(
                    preferences: card.notificationPreferences,
                    onPreferencesChanged: { newPrefs in
                        print("🟢 [ActionCardView] onPreferencesChanged called with svgPath=\(newPrefs.svgPath ?? "nil")")
                        card.notificationPreferences = newPrefs
                        print("🟢 [ActionCardView] card.notificationPreferences updated to svgPath=\(card.notificationPreferences.svgPath ?? "nil")")
                    },
                    parameters: $card.parameters
                )
            } else {
                ActionParametersView(type: card.type, parameters: $card.parameters)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorForType(card.type).opacity(0.3), lineWidth: 2)
        )
    }

    private func colorForType(_ type: ActionType) -> Color {
        switch type.color {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "red": return .red
        case "indigo": return .indigo
        case "gray": return .gray
        default: return .primary
        }
    }
}

// MARK: - ActionParametersView
struct ActionParametersView: View {
    let type: ActionType
    @Binding var parameters: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(type.requiredParameters, id: \.name) { param in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text(param.description)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if param.required {
                            Text("*")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }

                    switch param.type {
                    case .string:
                        if param.name == "body" || param.name == "script" || param.name == "message" {
                            // Multi-line text for body/script/message fields
                            TextField(param.description, text: binding(for: param.name), axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(3...6)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                        } else {
                            // Single-line text for other fields
                            TextField(param.description, text: binding(for: param.name))
                                .textFieldStyle(.roundedBorder)
                        }

                    case .number:
                        TextField(param.description, text: binding(for: param.name))
                            .textFieldStyle(.roundedBorder)

                    case .boolean:
                        Toggle(param.description, isOn: boolBinding(for: param.name))

                    default:
                        TextField(param.description, text: binding(for: param.name))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private func binding(for paramName: String) -> Binding<String> {
        Binding(
            get: { parameters[paramName] ?? "" },
            set: { parameters[paramName] = $0 }
        )
    }

    private func boolBinding(for paramName: String) -> Binding<Bool> {
        Binding(
            get: { parameters[paramName] == "true" },
            set: { parameters[paramName] = $0 ? "true" : "false" }
        )
    }
}

// MARK: - NotificationActionParametersView
struct NotificationActionParametersView: View {
    var preferences: NotificationPreferences  // Read-only initial value
    let onPreferencesChanged: (NotificationPreferences) -> Void  // Explicit callback
    @Binding var parameters: [String: String]  // Keep parameters binding
    @State private var currentPreferences: NotificationPreferences  // Track current state
    @State private var showingFilePicker = false
    @State private var showingIconPicker = false
    @State private var previewNotification = false
    @StateObject private var iconManager = SVGIconManager.shared

    init(preferences: NotificationPreferences, onPreferencesChanged: @escaping (NotificationPreferences) -> Void, parameters: Binding<[String: String]>) {
        self.preferences = preferences
        self.onPreferencesChanged = onPreferencesChanged
        self._parameters = parameters
        self._currentPreferences = State(initialValue: preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quick Presets
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
        .onChange(of: preferences) { newValue in
            print("🟣 [NotificationActionParametersView] Parent preferences changed")
            print("🟣 [NotificationActionParametersView] Old currentPreferences.svgPath=\(currentPreferences.svgPath ?? "nil")")
            print("🟣 [NotificationActionParametersView] New preferences.svgPath=\(newValue.svgPath ?? "nil")")
            currentPreferences = newValue
            print("🟣 [NotificationActionParametersView] Synced currentPreferences")
        }
    }

    // MARK: - Preset Section
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Presets")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                ForEach(NotificationPreferences.presetNames, id: \.self) { presetName in
                    Button(action: {
                        if let preset = NotificationPreferences.presets[presetName] {
                            currentPreferences = preset
                            onPreferencesChanged(preset)
                        }
                    }) {
                        Text(presetName)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
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
            if currentPreferences.hasSVGIcon {
                let _ = print("🟢 [ActionCardView UI] hasSVGIcon=true, svgPath=\(currentPreferences.svgPath ?? "nil")")
                let _ = print("🟢 [ActionCardView UI] extractedIconId=\(currentPreferences.extractedIconId ?? "nil")")
                let _ = print("🟢 [ActionCardView UI] iconManager.icons.count=\(iconManager.icons.count)")

                HStack(spacing: 12) {
                    // Icon preview card
                    HStack(spacing: 8) {
                        // Icon preview
                        if let iconId = currentPreferences.extractedIconId,
                           let icon = iconManager.icon(withId: iconId) {
                            let _ = print("🟢 [ActionCardView UI] Found icon: \(icon.name)")
                            // Bundled icon preview (from backend URL)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                    Text(icon.name)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                Text(icon.category.displayName)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } else if let svgPath = currentPreferences.svgPath {
                            let _ = print("🟡 [ActionCardView UI] No icon found in manager, showing custom SVG fallback")
                            let _ = print("🟡 [ActionCardView UI] svgPath: \(svgPath)")
                            // Custom SVG file path preview
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.fill")
                                        .font(.caption2)
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
                        HStack(spacing: 6) {
                            Text("Size:")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            TextField("W", value: Binding(
                                get: { Double(currentPreferences.svgWidth ?? 350) },
                                set: {
                                    var updated = currentPreferences
                                    updated.svgWidth = CGFloat($0)
                                    currentPreferences = updated
                                    onPreferencesChanged(updated)
                                }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)

                            Text("×")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            TextField("H", value: Binding(
                                get: { Double(currentPreferences.svgHeight ?? 320) },
                                set: {
                                    var updated = currentPreferences
                                    updated.svgHeight = CGFloat($0)
                                    currentPreferences = updated
                                    onPreferencesChanged(updated)
                                }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(6)

                    // Remove button
                    Button("Remove") {
                        var updated = currentPreferences
                        updated.svgPath = nil
                        updated.svgWidth = nil
                        updated.svgHeight = nil
                        currentPreferences = updated
                        onPreferencesChanged(updated)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            } else {
                // No icon selected - show selection buttons
                HStack(spacing: 8) {
                    // Browse bundled icons button
                    Button(action: {
                        showingIconPicker = true
                    }) {
                        HStack {
                            Image(systemName: "square.grid.3x3.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Browse Icons")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingIconPicker) {
                        SVGIconPickerView(
                            iconManager: iconManager,
                            selectedIconId: Binding(
                                get: { currentPreferences.extractedIconId },
                                set: { _ in /* Icon ID extracted from URL, no direct set */ }
                            ),
                            onSelect: { icon in
                                print("🔵 [NotificationActionParametersView] Icon selected: \(icon.id) - \(icon.name)")

                                // Build full backend URL for bundled icon
                                let iconURL = "http://localhost:8080/api/icons/\(icon.id).svg"
                                print("🔵 [NotificationActionParametersView] Built URL: \(iconURL)")

                                // Create mutable copy and modify
                                var updated = currentPreferences
                                updated.svgPath = iconURL
                                updated.svgWidth = updated.svgWidth ?? 350
                                updated.svgHeight = updated.svgHeight ?? 320
                                print("🔵 [NotificationActionParametersView] Modified copy: updated.svgPath = \(updated.svgPath ?? "nil")")

                                // Update local state first
                                currentPreferences = updated
                                print("🔵 [NotificationActionParametersView] currentPreferences updated, svgPath = \(currentPreferences.svgPath ?? "nil")")

                                // Then call parent callback
                                print("🔵 [NotificationActionParametersView] About to call onPreferencesChanged")
                                onPreferencesChanged(updated)
                                print("🔵 [NotificationActionParametersView] onPreferencesChanged returned")

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
                                .font(.caption)
                            Text("Custom SVG")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Choose from \(iconManager.icons.count) bundled icons or use your own")
                .font(.caption2)
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
                    var updated = currentPreferences
                    updated.svgPath = url.path
                    updated.svgWidth = updated.svgWidth ?? 350
                    updated.svgHeight = updated.svgHeight ?? 320
                    currentPreferences = updated
                    onPreferencesChanged(updated)
                }
            case .failure(let error):
                print("Error selecting SVG: \(error)")
            }
        }
    }

    // MARK: - Message Customization Section
    private var messageCustomizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message")
                .font(.subheadline)
                .fontWeight(.medium)

            TextField("Title (optional)", text: Binding(
                get: { parameters["title"] ?? "" },
                set: {
                    parameters["title"] = $0
                    // Sync to preferences for template variables
                    var updated = currentPreferences
                    updated.title = $0.isEmpty ? nil : $0
                    currentPreferences = updated
                    onPreferencesChanged(updated)
                }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Message body (optional)", text: Binding(
                get: { parameters["body"] ?? "" },
                set: {
                    parameters["body"] = $0
                    // Sync to preferences for template variables
                    var updated = currentPreferences
                    updated.message = $0.isEmpty ? nil : $0
                    currentPreferences = updated
                    onPreferencesChanged(updated)
                }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...4)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)

            Text("Variables: {scheduleName}, {routineName}, {time}")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Position Section
    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Position")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                ForEach(NotificationPosition.allCases, id: \.self) { position in
                    Button(action: {
                        var updated = currentPreferences
                        updated.position = position
                        currentPreferences = updated
                        onPreferencesChanged(updated)
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: position.iconName)
                                .font(.caption)
                            Text(position.displayName)
                                .font(.system(size: 9))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            currentPreferences.position == position
                                ? Color.accentColor
                                : Color(NSColor.controlBackgroundColor).opacity(0.5)
                        )
                        .foregroundColor(
                            currentPreferences.position == position
                                ? .white
                                : .primary
                        )
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Size Section
    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notification Size")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width: \(Int(currentPreferences.width ?? 450))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { currentPreferences.width ?? 450 },
                            set: {
                                var updated = currentPreferences
                                updated.width = $0
                                currentPreferences = updated
                                onPreferencesChanged(updated)
                            }
                        ),
                        in: 300...800,
                        step: 50
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Height: \(Int(currentPreferences.height ?? 220))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { currentPreferences.height ?? 220 },
                            set: {
                                var updated = currentPreferences
                                updated.height = $0
                                currentPreferences = updated
                                onPreferencesChanged(updated)
                            }
                        ),
                        in: 150...500,
                        step: 25
                    )
                }
            }
        }
    }

    // MARK: - Behavior Section
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Behavior")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Allow moving notification", isOn: Binding(
                get: { currentPreferences.moveable },
                set: {
                    var updated = currentPreferences
                    updated.moveable = $0
                    currentPreferences = updated
                    onPreferencesChanged(updated)
                }
            ))
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Enable screen blur", isOn: Binding(
                get: { currentPreferences.screenBlurEnabled },
                set: {
                    var updated = currentPreferences
                    updated.screenBlurEnabled = $0
                    currentPreferences = updated
                    onPreferencesChanged(updated)
                }
            ))
                .toggleStyle(.switch)
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-dismiss: \(Int(currentPreferences.autoDismissAfter ?? 20))s")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { currentPreferences.autoDismissAfter ?? 20.0 },
                        set: {
                            var updated = currentPreferences
                            updated.autoDismissAfter = $0
                            currentPreferences = updated
                            onPreferencesChanged(updated)
                        }
                    ),
                    in: 5...60,
                    step: 5
                )
            }
        }
    }

    // MARK: - Preview Section
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                showPreviewNotification()
            }) {
                HStack {
                    Image(systemName: "eye")
                        .font(.caption)
                    Text("Preview Notification")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.2))
                .foregroundColor(.accentColor)
                .cornerRadius(6)
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

    private func showPreviewNotification() {
        print("🔴 [Preview] Showing preview notification")
        print("🔴 [Preview] currentPreferences.svgPath = \(currentPreferences.svgPath ?? "nil")")
        print("🔴 [Preview] currentPreferences.svgWidth = \(currentPreferences.svgWidth ?? 0)")
        print("🔴 [Preview] currentPreferences.svgHeight = \(currentPreferences.svgHeight ?? 0)")

        _ = VibeNotifyConfig.showScheduleNotification(
            scheduleName: "Preview Notification",
            routineName: "Preview Action",
            scheduledTime: Date(),
            notes: nil,
            preferences: currentPreferences
        )

        previewNotification = true
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 16) {
        ScheduleActionCardView(
            card: .constant(ScheduleActionCard(
                type: .notification,
                parameters: ["title": "Test Notification", "body": "This is a test"]
            )),
            onRemove: {}
        )

        ScheduleActionCardView(
            card: .constant(ScheduleActionCard(
                type: .openLink,
                parameters: ["url": "https://meet.google.com/abc-def-ghi"]
            )),
            onRemove: {}
        )
    }
    .padding()
    .frame(width: 600)
}
