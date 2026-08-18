import SwiftUI
import UniformTypeIdentifiers
import SVGView
import Logging

// MARK: - ScheduleActionCard Model
struct ScheduleActionCard: Identifiable, Equatable {
    let id: String
    var type: ActionType
    var parameters: [String: String]
    var notificationPreferences: NotificationPreferences = GlobalNotificationSettings.current.basePreferences() // For notification actions
    /// Whether this action overrides the global notification appearance.
    ///
    /// Not persisted as a flag of its own: the *presence* of the appearance
    /// keys in `parameters` is the persisted state, and this is derived from
    /// them on load (`GlobalNotificationSettings.overridesAppearance`) and
    /// written back to them on save. That way an action authored by the CLI or
    /// MCP with only a `position` reads correctly here without ever having
    /// passed through this app, and there is no second copy of the truth to
    /// drift.
    var overridesAppearance: Bool = false

    static func == (lhs: ScheduleActionCard, rhs: ScheduleActionCard) -> Bool {
        return lhs.id == rhs.id &&
               lhs.type == rhs.type &&
               lhs.parameters == rhs.parameters &&
               lhs.overridesAppearance == rhs.overridesAppearance &&
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
                // A brand-new action inherits the global look — no appearance
                // keys written, so `overridesAppearance` stays false and the
                // controls it seeds show what the alert will actually look like.
                self.notificationPreferences = GlobalNotificationSettings.current.basePreferences()
                self.overridesAppearance = false
            } else {
                // Loading existing action - deserialize from parameters
                print("DEBUG [ScheduleActionCard.init]: Loading existing notification action from parameters")
                self.parameters = parameters
                self.notificationPreferences = Self.deserializeNotificationPreferences(from: parameters)
                self.overridesAppearance = GlobalNotificationSettings.overridesAppearance(parameters)

                print("DEBUG [ScheduleActionCard.init]: Final prefs: title=\(notificationPreferences.title ?? "nil"), position=\(notificationPreferences.position), overridesAppearance=\(overridesAppearance)")
            }
        } else {
            // Seed missing values from each parameter's defaultValue (e.g. system
            // command's "sleep") so dropdowns never render blank/undefined.
            // Existing values (editing an existing action) are preserved.
            self.parameters = type.seedingDefaults(into: parameters)
            // notificationPreferences already has .default value
        }
    }

    func toAction(profileId: String, scheduleName: String? = nil, scheduleNotes: String? = nil, routineName: String? = nil) -> Action {
        var actionParams = parameters

        // Serialize notification preferences into parameters for notification actions
        if type == .notification {
            actionParams = Self.serializeNotificationPreferences(
                notificationPreferences,
                into: actionParams,
                overridesAppearance: overridesAppearance
            )

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

    /// Writes an action's *content* always, and its *appearance* only when the
    /// action actually overrides the global settings.
    ///
    /// The `overridesAppearance == false` branch **removes** the appearance
    /// keys rather than leaving whatever was there. That is what makes the
    /// inheritance real: writing `position`/`moveable`/`screen_blur_enabled`
    /// unconditionally — as this used to — meant every action ever opened in
    /// the editor pinned its own appearance forever, and a later change to the
    /// global settings would reach none of them.
    private static func serializeNotificationPreferences(
        _ prefs: NotificationPreferences,
        into params: [String: String],
        overridesAppearance: Bool
    ) -> [String: String] {
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

        if overridesAppearance {
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
        } else {
            result = GlobalNotificationSettings.clearingAppearance(result)
        }

        if let taskTimerSeconds = prefs.taskTimerSeconds {
            result["task_timer_seconds"] = String(taskTimerSeconds)
        } else {
            result.removeValue(forKey: "task_timer_seconds")
        }
        if let unitLabel = prefs.taskTimerUnitLabel, !unitLabel.isEmpty {
            result["task_timer_unit_label"] = unitLabel
        }
        if let completionLabel = prefs.taskTimerCompletionLabel, !completionLabel.isEmpty {
            result["task_timer_completion_label"] = completionLabel
        }

        result = Self.applyingWebPanel(prefs, to: result)

        return result
    }

    /// The four `web_*` keys, written together and removed together.
    ///
    /// Removed together is the load-bearing half: clearing the activity has to
    /// clear the width and the autoplay flag with it, or an action switched
    /// from a Short back to "countdown only" keeps a 36% column width that
    /// nothing on screen explains any more, and reinstates it the moment any
    /// activity is picked again.
    static func applyingWebPanel(
        _ prefs: NotificationPreferences, to parameters: [String: String]
    ) -> [String: String] {
        var result = parameters
        guard let spec = prefs.webURLSpec, !spec.isEmpty else {
            for key in ["web_url", "web_side", "web_width", "web_autoplay", "web_loop"] {
                result.removeValue(forKey: key)
            }
            return result
        }
        result["web_url"] = spec
        if let fraction = prefs.webWidthFraction {
            result["web_width"] = String(format: "%.2f", Double(fraction))
        }
        if let side = prefs.webPlacement, !side.isEmpty {
            result["web_side"] = side
        }
        result["web_autoplay"] = String(prefs.webAutoplay)
        result["web_loop"] = String(prefs.webLoops)
        return result
    }

    /// The same resolution the delivery path performs
    /// (`NotificationManager.deserializeNotificationPreferences`), through the
    /// same function: global settings as defaults, per-action keys winning
    /// where present. Sharing it is what keeps the editor's controls showing
    /// the values the alert will actually be rendered with, including for the
    /// keys this action does not override.
    private static func deserializeNotificationPreferences(from params: [String: String]) -> NotificationPreferences {
        GlobalNotificationSettings.current.resolving(actionParameters: params)
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
    /// Closed by default: the appearance controls it holds are the ones the
    /// global settings now answer for.
    @State private var advancedExpanded = false
    @ObservedObject private var iconManager = SVGIconManager.shared

    // SVG icon preview state
    @State private var svgPreviewData: Data?
    @State private var isLoadingSVG = false

    // Logger
    private let logger = Logger(label: "com.vibecare.notification-action-params")

    var body: some View {
        @Bindable var vm = viewModel

        VStack(alignment: .leading, spacing: 16) {
            // Content: what this notification says. Always visible — it is the
            // only part of an action that has no global counterpart.
            svgIconSection

            messageCustomizationSection

            breakCountdownSection

            breakActivitySection

            // Appearance: how it looks. Collapsed by default, because the
            // answer for almost every action is "the same as everything else",
            // and that answer now lives in Settings › Notifications.
            appearanceDisclosure
        }
    }

    // MARK: - Appearance Disclosure

    /// The demoted per-action appearance controls.
    ///
    /// Closed by default and headed by a line that says, in as many words,
    /// where the appearance is coming from — an action that overrides nothing
    /// should not make the user open a disclosure to find that out.
    private var appearanceDisclosure: some View {
        @Bindable var vm = viewModel

        return DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(
                    get: { vm.overridesAppearance },
                    set: { viewModel.setOverridesAppearance($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Override global appearance for this action")
                            .font(.caption)
                        Text("Turn off to follow Settings › Notifications.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Group {
                    presetSection
                    positionSection
                    sizeSection
                    behaviorSection
                }
                .disabled(!vm.overridesAppearance)
                .opacity(vm.overridesAppearance ? 1 : 0.5)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Advanced")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(inheritanceSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var inheritanceSummary: String {
        viewModel.overridesAppearance
            ? "Custom appearance for this action"
            : "Using global notification settings"
    }

    // MARK: - Break Countdown Section

    /// The break duration, which is content rather than appearance: whether an
    /// action runs a break is what the action *is*. Its wording — the unit and
    /// completion labels — comes from the global settings.
    private var breakCountdownSection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Break Countdown")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle("Show a break countdown", isOn: Binding(
                get: { vm.preferences.taskTimerSeconds != nil },
                set: { vm.preferences.taskTimerSeconds = $0 ? 20 : nil }
            ))
            .toggleStyle(.switch)
            .font(.caption)

            if let seconds = vm.preferences.taskTimerSeconds {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duration: \(Int(seconds))s")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { seconds },
                            set: { vm.preferences.taskTimerSeconds = $0 }
                        ),
                        in: 5...300,
                        step: 5
                    )
                }

                Text("Shown as a full-screen countdown labelled “\(GlobalNotificationSettings.current.breakUnitLabel)”, ending in “\(GlobalNotificationSettings.current.breakCompletionLabel)”. Change the wording in Settings › Notifications.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// What the break *is*, when it is more than a countdown: a page opened
    /// beside the timer, from a short curated list or a URL of the author's own.
    ///
    /// A list rather than a search box on purpose. A break is twenty seconds
    /// long, and a user choosing what to watch during one has already spent it
    /// — so the choosing happens here, once, and costs a click at break time.
    private var breakActivitySection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 8) {
            Text("Break Activity")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Activity", selection: Binding(
                get: { vm.preferences.webURLSpec ?? "" },
                set: { apply(activityURL: $0) }
            )) {
                Text("None — countdown only").tag("")
                ForEach(BreakActivity.Focus.allCases) { focus in
                    Section(focus.title) {
                        ForEach(BreakActivity.all(in: focus)) { activity in
                            Text(activity.title).tag(activity.url)
                        }
                    }
                }
                // Keeps a hand-typed URL selectable rather than snapping the
                // picker back to "None" the moment it stops matching a
                // catalogue entry.
                if let spec = vm.preferences.webURLSpec,
                   !spec.isEmpty, BreakActivity.activity(withURL: spec) == nil {
                    Section("Custom") {
                        Text(spec).tag(spec)
                    }
                }
            }
            .labelsHidden()
            .font(.caption)

            if let spec = vm.preferences.webURLSpec, !spec.isEmpty {
                TextField("https://… or plugin:<id>", text: Binding(
                    get: { spec },
                    set: { vm.preferences.webURLSpec = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

                // Says "muted" because it always is: browsers grant muted
                // autoplay and refuse unmuted autoplay without a user gesture,
                // so a label promising sound would be promising something no
                // policy allows. The player keeps its own unmute control.
                Toggle("Start playing automatically (muted)", isOn: $vm.preferences.webAutoplay)
                    .toggleStyle(.switch)
                    .font(.caption)

                Toggle("Loop until the break ends", isOn: $vm.preferences.webLoops)
                    .toggleStyle(.switch)
                    .font(.caption)

                Text("Opens beside the countdown, filling most of the screen. YouTube links — Shorts and ones with a start time included — become an embedded player automatically. Clicking the page will not dismiss the alert; Done, Skip and ESC still will.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Applies a picked activity: the URL always, and the column width and
    /// break duration only as *defaults*.
    ///
    /// Width comes along because a vertical Short in the landscape column is
    /// letterboxed into two black wings, which is a property of the video and
    /// not something an author should have to know. The duration is seeded only
    /// when none is set — an author who already chose 20 seconds meant it, and
    /// replacing that with a suggestion would overwrite a decision with a guess.
    private func apply(activityURL: String) {
        let vm = viewModel
        guard !activityURL.isEmpty else {
            vm.preferences.webURLSpec = nil
            return
        }
        vm.preferences.webURLSpec = activityURL
        guard let activity = BreakActivity.activity(withURL: activityURL) else { return }
        vm.preferences.webWidthFraction = CGFloat(activity.widthFraction)
        if vm.preferences.taskTimerSeconds == nil {
            vm.preferences.taskTimerSeconds = TimeInterval(activity.seconds)
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
