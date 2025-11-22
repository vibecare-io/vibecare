import SwiftUI

struct TemplateCustomizationView: View {
    let template: RoutineScheduleTemplate
    @Binding var routineName: String
    @Binding var scheduleName: String
    @Binding var scheduleDescription: String
    @Binding var routineIcon: String
    @Binding var routineColor: String
    @Binding var times: [Date]
    @Binding var actions: [ActionTemplate]

    @ObservedObject var routineViewModel: RoutineViewModel

    let onBack: () -> Void
    let onNext: () -> Void

    @State private var expandedSection: String? = "times"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Template preview
                    templatePreviewCard

                    Divider()

                    // Routine details section
                    routineDetailsSection

                    Divider()

                    // Schedule times section
                    scheduleTimesSection

                    Divider()

                    // Actions section
                    actionsSection
                }
                .padding(20)
            }

            Divider()

            // Footer
            footerView
        }
        .frame(minWidth: 700, minHeight: 600)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize Your Routine")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Adjust the details to match your needs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Template Preview Card

    private var templatePreviewCard: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color(routineColor).opacity(0.15))
                    .frame(width: 60, height: 60)

                Image(systemName: routineIcon)
                    .font(.system(size: 28))
                    .foregroundColor(Color(routineColor))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(routineName)
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(scheduleName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(frequencyDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(routineColor).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Routine Details Section

    private var routineDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Routine Details",
                icon: "list.bullet",
                sectionId: "routine"
            )

            VStack(alignment: .leading, spacing: 12) {
                // Routine name with autocomplete dropdown
                VStack(alignment: .leading, spacing: 6) {
                    Text("Routine Name")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        TextField("e.g., Morning Workout", text: $routineName)
                            .textFieldStyle(.roundedBorder)

                        // Dropdown menu for existing routines
                        if !filteredRoutineSuggestions.isEmpty {
                            Menu {
                                ForEach(filteredRoutineSuggestions) { routine in
                                    Button {
                                        routineName = routine.name
                                        routineIcon = routine.iconName
                                        routineColor = routine.color
                                    } label: {
                                        Label {
                                            Text(routine.name)
                                        } icon: {
                                            Image(systemName: routine.iconName)
                                                .foregroundColor(Color(routine.color))
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .imageScale(.large)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose from existing routines")
                        }
                    }
                }

                // Schedule name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Schedule Name")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("e.g., Daily at 7 AM", text: $scheduleName)
                        .textFieldStyle(.roundedBorder)
                }

                // Schedule description (optional)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Description")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("(Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Add notes about this schedule...", text: $scheduleDescription)
                        .textFieldStyle(.roundedBorder)
                }

                // Icon and color picker
                HStack(spacing: 20) {
                    // Icon picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Icon")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        iconPicker
                    }

                    // Color picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Color")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        colorPicker
                    }
                }
            }
        }
    }

    // MARK: - Schedule Times Section

    private var scheduleTimesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Schedule Times",
                icon: "clock",
                sectionId: "times"
            )

            timePickersList
        }
    }

    private var timePickersList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                timePickerRow(index: index, time: time)
            }

            // Add time button
            Button {
                withAnimation {
                    times.append(Date())
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Another Time")
                        .font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
    }

    private func timePickerRow(index: Int, time: Date) -> some View {
        HStack {
            DatePicker(
                "Time \(index + 1)",
                selection: Binding(
                    get: { times[index] },
                    set: { times[index] = $0 }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()

            Spacer()

            // Remove time button
            if times.count > 1 {
                Button {
                    withAnimation {
                        _ = times.remove(at: index)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this time")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                title: "Actions",
                icon: "bolt.fill",
                sectionId: "actions"
            )

            if actions.isEmpty {
                emptyActionsView
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        actionRow(action: action, index: index)
                    }
                }
            }

            // Add action button
            addActionButton
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String, sectionId: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundColor(.accentColor)

            Text(title)
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()
        }
    }

    // MARK: - Icon Picker

    private var iconPicker: some View {
        let commonIcons = [
            "list.bullet", "star.fill", "heart.fill", "bolt.fill",
            "bell.fill", "calendar", "clock.fill", "flag.fill",
            "checkmark.circle.fill", "plus.circle.fill", "minus.circle.fill",
            "house.fill", "briefcase.fill", "book.fill", "cart.fill"
        ]

        return HStack(spacing: 8) {
            ForEach(commonIcons.prefix(8), id: \.self) { icon in
                Button {
                    routineIcon = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(routineIcon == icon ? .white : .primary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(routineIcon == icon ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Color Picker

    private var colorPicker: some View {
        let colors = ["blue", "green", "red", "orange", "purple", "pink", "yellow", "gray"]

        return HStack(spacing: 8) {
            ForEach(colors, id: \.self) { color in
                Button {
                    routineColor = color
                } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: routineColor == color ? 3 : 0)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Action Row

    private func actionRow(action: ActionTemplate, index: Int) -> some View {
        HStack(spacing: 12) {
            // Action icon
            Image(systemName: actionIconName(action.type))
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)

            // Action info
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(actionTypeLabel(action.type))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Remove button
            Button {
                withAnimation {
                    let _ = actions.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove action")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Empty Actions View

    private var emptyActionsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No actions configured")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Add actions to make this schedule do something")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Add Action Button

    private var addActionButton: some View {
        Menu {
            Button {
                addNotificationAction()
            } label: {
                Label("Notification", systemImage: "bell.fill")
            }

            Button {
                addLinkAction()
            } label: {
                Label("Open Link", systemImage: "link")
            }

            Button {
                addLogAction()
            } label: {
                Label("Log Entry", systemImage: "text.alignleft")
            }
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add Action")
                    .font(.subheadline)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Back") {
                onBack()
            }

            Spacer()

            Button("Review & Create") {
                onNext()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                     scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20)
    }

    // MARK: - Routine Suggestions

    private var filteredRoutineSuggestions: [Routine] {
        // Show all routines if field is empty, or filter by what's typed
        if routineName.isEmpty {
            return Array(routineViewModel.routines.prefix(10))
        }

        let lowercased = routineName.lowercased()
        return routineViewModel.routines.filter {
            $0.name.lowercased().contains(lowercased)
        }.prefix(10).map { $0 }
    }

    // MARK: - Helpers

    private var frequencyDescription: String {
        if times.count == 1 {
            return "Once per occurrence"
        } else {
            return "\(times.count) times per occurrence"
        }
    }

    private func actionIconName(_ type: ActionType) -> String {
        switch type {
        case .notification: return "bell.fill"
        case .openLink: return "link"
        case .sendEmail: return "envelope.fill"
        case .runScript: return "terminal.fill"
        case .playSound: return "speaker.wave.2.fill"
        case .systemCommand: return "command"
        case .apiCall: return "network"
        case .logEntry: return "text.alignleft"
        }
    }

    private func actionTypeLabel(_ type: ActionType) -> String {
        switch type {
        case .notification: return "Show notification"
        case .openLink: return "Open URL"
        case .sendEmail: return "Send email"
        case .runScript: return "Run script"
        case .playSound: return "Play sound"
        case .systemCommand: return "System command"
        case .apiCall: return "API call"
        case .logEntry: return "Log message"
        }
    }

    // MARK: - Action Creation

    private func addNotificationAction() {
        let newAction = ActionTemplate(
            type: .notification,
            name: "Notification",
            parameters: [
                "title": "\(routineName) Reminder",
                "body": "Time for: \(scheduleName)",
                "sound": "default"
            ]
        )
        withAnimation {
            actions.append(newAction)
        }
    }

    private func addLinkAction() {
        let newAction = ActionTemplate(
            type: .openLink,
            name: "Open Link",
            parameters: [
                "url": "https://example.com"
            ]
        )
        withAnimation {
            actions.append(newAction)
        }
    }

    private func addLogAction() {
        let newAction = ActionTemplate(
            type: .logEntry,
            name: "Log Entry",
            parameters: [
                "message": "\(routineName) executed at {time}"
            ]
        )
        withAnimation {
            actions.append(newAction)
        }
    }
}

// MARK: - Preview

#Preview {
    let template = RoutineScheduleTemplate.allTemplates.first ?? RoutineScheduleTemplate(
        id: "preview",
        category: .daily,
        routineName: "Preview Routine",
        routineIcon: "star.fill",
        routineColor: "blue",
        scheduleName: "Preview Schedule",
        rruleString: "FREQ=DAILY",
        defaultTimes: [TimeComponents(hour: 9, minute: 0)]
    )

    TemplateCustomizationView(
        template: template,
        routineName: .constant(template.routineName),
        scheduleName: .constant(template.scheduleName),
        scheduleDescription: .constant(template.scheduleDescription),
        routineIcon: .constant(template.routineIcon),
        routineColor: .constant(template.routineColor),
        times: .constant(template.defaultTimes.map { $0.toDate() }),
        actions: .constant(template.suggestedActions),
        routineViewModel: RoutineViewModel(),
        onBack: {},
        onNext: {}
    )
}
