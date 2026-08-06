import SwiftUI
import UniformTypeIdentifiers
import SVGView
import Logging

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
        } else {
            // No icon selected - clear parameter
            result.removeValue(forKey: "svg_path")
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
        result["screen_blur_intensity"] = prefs.screenBlurIntensity.rawValue

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
        let screenBlurIntensity = params["screen_blur_intensity"].flatMap { BlurIntensity(rawValue: $0) } ?? .medium

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
            screenBlurEnabled: screenBlurEnabled,
            screenBlurIntensity: screenBlurIntensity
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
                NotificationActionParametersViewWrapper(card: $card)
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
                        if let allowed = param.allowedValues {
                            // Fixed vocabulary -> dropdown; stores the raw term.
                            Picker(param.description, selection: binding(for: param.name)) {
                                ForEach(allowed, id: \.self) { raw in
                                    Text(ActionParameter.displayLabel(for: raw)).tag(raw)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        } else if isMultiline(param) {
                            // Multi-line text for long free-text fields
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

    /// Long free-text fields render multi-line — except the system command's
    /// short overlay `message`, which stays single-line.
    private func isMultiline(_ param: ActionParameter) -> Bool {
        if type == .systemCommand { return false }
        return param.name == "body" || param.name == "script" || param.name == "message"
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
    let viewModel: NotificationActionViewModel
    @State private var showingFilePicker = false
    @State private var showingIconPicker = false
    @State private var previewNotification = false
    @ObservedObject private var iconManager = SVGIconManager.shared

    // SVG icon preview state
    @State private var svgPreviewData: Data?
    @State private var isLoadingSVG = false

    // Logger
    private let logger = Logger(label: "com.vibecare.notification-action-params")

    var body: some View {
        @Bindable var vm = viewModel

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
                            viewModel.applyPreset(preset)
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
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Icon")
                .font(.subheadline)
                .fontWeight(.medium)

            // Show selected icon preview
            if vm.preferences.hasSVGIcon {
                HStack(spacing: 12) {
                    // Icon preview card
                    HStack(spacing: 8) {
                        // SVG Icon visual preview
                        iconPreviewView
                            .frame(width: 48, height: 48)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )

                        // Icon metadata
                        if let iconId = vm.preferences.extractedIconId,
                           let icon = iconManager.icon(withId: iconId) {
                            // Bundled icon metadata
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
                        } else if let svgPath = vm.preferences.svgPath {
                            // Custom SVG file path metadata
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
                                get: { Double(vm.preferences.svgWidth ?? 350) },
                                set: { vm.updateIconSize(width: CGFloat($0), height: vm.preferences.svgHeight ?? 320) }
                            ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)

                            Text("×")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            TextField("H", value: Binding(
                                get: { Double(vm.preferences.svgHeight ?? 320) },
                                set: { vm.updateIconSize(width: vm.preferences.svgWidth ?? 350, height: CGFloat($0)) }
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
                        vm.removeIcon()
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
                                get: { vm.preferences.extractedIconId },
                                set: { _ in /* Icon ID extracted from URL, no direct set */ }
                            ),
                            onSelect: { icon in
                                print("🔍 [ActionCardView.onSelect] Selected icon.id: \(icon.id)")
                                print("🔍 [ActionCardView.onSelect] Selected icon.name: \(icon.name)")

                                // Build full backend URL for bundled icon
                                let iconURL = NetworkConfiguration.buildIconURL(iconId: icon.id)
                                print("🔍 [ActionCardView.onSelect] Built iconURL: \(iconURL)")

                                vm.updateIconURL(iconURL)
                                print("🔍 [ActionCardView.onSelect] Called vm.updateIconURL()")

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
                    vm.updateIconURL(url.path)
                }
            case .failure(let error):
                print("Error selecting SVG: \(error)")
            }
        }
    }

    // MARK: - Message Customization Section
    private var messageCustomizationSection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Message")
                .font(.subheadline)
                .fontWeight(.medium)

            TextField("Title (optional)", text: Binding(
                get: { vm.preferences.title ?? "" },
                set: { vm.updateTitle($0) }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Message body (optional)", text: Binding(
                get: { vm.preferences.message ?? "" },
                set: { vm.updateMessage($0) }
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
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Position")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                ForEach(NotificationPosition.allCases, id: \.self) { position in
                    Button(action: {
                        vm.preferences.position = position
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
                            vm.preferences.position == position
                                ? Color.accentColor
                                : Color(NSColor.controlBackgroundColor).opacity(0.5)
                        )
                        .foregroundColor(
                            vm.preferences.position == position
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
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Notification Size")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Width: \(Int(vm.preferences.width ?? 450))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { vm.preferences.width ?? 450 },
                            set: { vm.preferences.width = $0 }
                        ),
                        in: 300...800,
                        step: 50
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Height: \(Int(vm.preferences.height ?? 220))")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { vm.preferences.height ?? 220 },
                            set: { vm.preferences.height = $0 }
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
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Behavior")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Allow moving notification", isOn: $vm.preferences.moveable)
                .toggleStyle(.switch)
                .font(.caption)

            Toggle("Enable screen blur", isOn: $vm.preferences.screenBlurEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            // Blur intensity picker (shown when blur is enabled)
            if vm.preferences.screenBlurEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blur Intensity")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        ForEach(BlurIntensity.allCases, id: \.self) { intensity in
                            Button(action: {
                                vm.preferences.screenBlurIntensity = intensity
                            }) {
                                VStack(spacing: 2) {
                                    Image(systemName: intensity.iconName)
                                        .font(.caption)
                                    Text(intensity.displayName)
                                        .font(.system(size: 9))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    vm.preferences.screenBlurIntensity == intensity
                                        ? Color.accentColor
                                        : Color(NSColor.controlBackgroundColor).opacity(0.5)
                                )
                                .foregroundColor(
                                    vm.preferences.screenBlurIntensity == intensity
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-dismiss: \(Int(vm.preferences.autoDismissAfter ?? 20))s")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { vm.preferences.autoDismissAfter ?? 20.0 },
                        set: { vm.preferences.autoDismissAfter = $0 }
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
        logger.debug("🔍 showPreviewNotification - START", metadata: [
            "svgPath": "\(viewModel.preferences.svgPath ?? "nil")",
            "svgWidth": "\(viewModel.preferences.svgWidth?.description ?? "nil")",
            "svgHeight": "\(viewModel.preferences.svgHeight?.description ?? "nil")",
            "svgSize": "\(viewModel.preferences.svgSize?.debugDescription ?? "nil")",
            "resolvedSVGPath": "\(viewModel.preferences.resolvedSVGPath ?? "nil")",
            "hasSVGIcon": "\(viewModel.preferences.hasSVGIcon)"
        ])

        logger.debug("🔍 showPreviewNotification - Calling showScheduleNotification()")

        _ = VibeNotifyConfig.showScheduleNotification(
            scheduleName: "Preview Notification",
            routineName: "Preview Action",
            scheduledTime: Date(),
            notes: nil,
            preferences: viewModel.preferences
        )

        logger.debug("🔍 showPreviewNotification - END")
        previewNotification = true
    }

    // MARK: - Icon Preview

    private var iconPreviewView: some View {
        Group {
            if let data = svgPreviewData {
                // Render SVG from data
                SVGView(data: data)
                    .frame(width: 40, height: 40)
            } else if isLoadingSVG {
                // Show loading indicator
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 40, height: 40)
            } else {
                // Show placeholder
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
                    .frame(width: 40, height: 40)
            }
        }
        .task(id: viewModel.preferences.svgPath) {
            // Reload SVG when the path changes
            await loadSVGPreview()
        }
    }

    private func loadSVGPreview() async {
        guard let svgPath = viewModel.preferences.svgPath else {
            await MainActor.run {
                svgPreviewData = nil
                isLoadingSVG = false
            }
            return
        }

        await MainActor.run {
            isLoadingSVG = true
        }

        do {
            // Try to create URL from the path
            let url: URL
            if svgPath.starts(with: "http://") || svgPath.starts(with: "https://") {
                // Backend URL - fetch from network
                guard let networkURL = URL(string: svgPath) else {
                    await MainActor.run {
                        isLoadingSVG = false
                    }
                    return
                }
                url = networkURL
            } else {
                // Local file path
                url = URL(fileURLWithPath: svgPath)
            }

            let data = try await URLSession.shared.data(from: url).0
            await MainActor.run {
                self.svgPreviewData = data
                self.isLoadingSVG = false
            }
        } catch {
            print("Error loading SVG preview: \(error)")
            await MainActor.run {
                self.isLoadingSVG = false
            }
        }
    }
}

// MARK: - Wrapper for inline card editing
struct NotificationActionParametersViewWrapper: View {
    @Binding var card: ScheduleActionCard
    var viewModel: NotificationActionViewModel

    init(card: Binding<ScheduleActionCard>) {
        self._card = card
        // Pass @Observable object directly - no property wrapper needed
        self.viewModel = NotificationActionViewModel(
            preferences: card.wrappedValue.notificationPreferences,
            parameters: card.wrappedValue.parameters
        )
    }

    var body: some View {
        @Bindable var vm = viewModel  // Establish observation binding

        print("🔍 [Wrapper.body] Body evaluating - preferences.svgPath: \(vm.preferences.svgPath ?? "nil")")
        print("🔍 [Wrapper.body] preferences object ID: \(ObjectIdentifier(vm.preferences))")

        return NotificationActionParametersView(viewModel: viewModel)
            .onChange(of: vm.preferences.svgPath) { oldPath, newPath in
                print("🔍 [onChange.svgPath] FIRED! old: \(oldPath ?? "nil"), new: \(newPath ?? "nil")")
                card.notificationPreferences = viewModel.preferences
            }
            .onChange(of: vm.preferences.title) { _, _ in
                print("🔍 [onChange.title] FIRED!")
                card.notificationPreferences = viewModel.preferences
            }
            .onChange(of: vm.preferences.message) { _, _ in
                print("🔍 [onChange.message] FIRED!")
                card.notificationPreferences = viewModel.preferences
            }
            .onChange(of: vm.parameters) { _, newParams in
                print("🔍 [onChange.parameters] FIRED!")
                card.parameters = newParams
            }
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
