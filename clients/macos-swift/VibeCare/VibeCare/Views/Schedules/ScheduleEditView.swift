import SwiftUI

struct ScheduleEditView: View {
    let routineId: String
    @ObservedObject var scheduleViewModel: ScheduleViewModel
    let isCreating: Bool
    let schedule: Schedule?
    let onDismiss: () -> Void

    @State private var scheduleName: String = ""
    @State private var selectedTemplate: String = ""
    @State private var customRRule: String = ""
    @State private var useTemplate: Bool = true
    @State private var startDate: Date = Date()
    @State private var notes: String = ""
    @State private var enabled: Bool = true
    @State private var showingAdvanced: Bool = false
    @State private var validationError: String?

    // Template selection
    @State private var availableTemplates: [String] = []

    init(
        routineId: String,
        scheduleViewModel: ScheduleViewModel,
        schedule: Schedule? = nil,
        isCreating: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.routineId = routineId
        self.scheduleViewModel = scheduleViewModel
        self.schedule = schedule
        self.isCreating = isCreating
        self.onDismiss = onDismiss

        // Initialize state based on schedule
        if let schedule = schedule {
            self._scheduleName = State(initialValue: schedule.name)
            self._customRRule = State(initialValue: schedule.recurrenceJSON)
            self._useTemplate = State(initialValue: false)
            self._startDate = State(initialValue: schedule.dtstart)
            self._notes = State(initialValue: schedule.notes)
            self._enabled = State(initialValue: schedule.enabled)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Schedule Details
                    scheduleDetailsSection

                    // Recurrence Configuration
                    recurrenceSection

                    // Timing and Options
                    timingSection

                    // Preview
                    previewSection
                }
                .padding(24)
            }
            .navigationTitle(isCreating ? "Add Schedule" : "Edit Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Save") {
                        saveSchedule()
                    }
                    .disabled(!isValidSchedule)
                }
            }
        }
        .onAppear {
            availableTemplates = scheduleViewModel.getAvailableTemplates()
            if selectedTemplate.isEmpty && !availableTemplates.isEmpty {
                selectedTemplate = availableTemplates[0]
            }
        }
    }

    // MARK: - Schedule Details Section

    private var scheduleDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("Schedule name", text: $scheduleName)
                    .textFieldStyle(.roundedBorder)

                if let error = validationError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.subheadline)
                    .fontWeight(.medium)

                TextField("Optional notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }

            Toggle("Enabled", isOn: $enabled)
        }
    }

    // MARK: - Recurrence Section

    private var recurrenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recurrence")
                .font(.headline)

            Picker("Configuration Type", selection: $useTemplate) {
                Text("Use Template").tag(true)
                Text("Custom JSON").tag(false)
            }
            .pickerStyle(.segmented)

            if useTemplate {
                templateSelectionView
            } else {
                customRRuleView
            }
        }
    }

    private var templateSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Template")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Template", selection: $selectedTemplate) {
                ForEach(availableTemplates, id: \.self) { template in
                    Text(template).tag(template)
                }
            }
            .pickerStyle(.menu)

            // Template examples
            VStack(alignment: .leading, spacing: 8) {
                Text("Examples")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(Array(availableTemplates.prefix(6)), id: \.self) { template in
                        Button(template) {
                            selectedTemplate = template
                            if scheduleName.isEmpty {
                                scheduleName = template
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var customRRuleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RRule JSON")
                .font(.subheadline)
                .fontWeight(.medium)

            TextField("Enter RRule JSON", text: $customRRule, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(5...10)
                .font(.system(.body, design: .monospaced))

            // JSON Examples
            VStack(alignment: .leading, spacing: 8) {
                Text("Common Patterns")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                DisclosureGroup("View Examples") {
                    VStack(alignment: .leading, spacing: 4) {
                        jsonExample("Every 20 minutes", """
                        {"freq": "MINUTELY", "interval": 20}
                        """)

                        jsonExample("Daily at 9 AM", """
                        {"freq": "DAILY", "byhour": [9], "byminute": [0]}
                        """)

                        jsonExample("Weekdays at 2 PM", """
                        {"freq": "WEEKLY", "byday": ["MO","TU","WE","TH","FR"], "byhour": [14], "byminute": [0]}
                        """)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func jsonExample(_ title: String, _ json: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)

            Text(json)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture {
                    customRRule = json
                }
        }
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timing")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Start Date & Time")
                    .font(.subheadline)
                    .fontWeight(.medium)

                DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
            }
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Display Name:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(previewDisplayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let nextExecution = previewNextExecution {
                    HStack {
                        Text("Next Execution:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text(nextExecution, style: .relative)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                if isValidRRule {
                    Label("Valid recurrence rule", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Label("Invalid recurrence rule", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Computed Properties

    private var currentRRuleJSON: String {
        if useTemplate, !selectedTemplate.isEmpty {
            if let rule = scheduleViewModel.getTemplateRule(for: selectedTemplate) {
                return (try? rule.toJSON()) ?? "{}"
            }
        }
        return customRRule
    }

    private var previewDisplayName: String {
        do {
            let rule = try RRule.fromJSON(currentRRuleJSON)
            return rule.humanReadableDescription
        } catch {
            return "Invalid rule"
        }
    }

    private var previewNextExecution: Date? {
        do {
            let rule = try RRule.fromJSON(currentRRuleJSON)
            return rule.nextExecution(after: startDate)
        } catch {
            return nil
        }
    }

    private var isValidRRule: Bool {
        do {
            _ = try RRule.fromJSON(currentRRuleJSON)
            return true
        } catch {
            return false
        }
    }

    private var isValidSchedule: Bool {
        let validation = scheduleViewModel.validateSchedule(
            name: scheduleName,
            recurrenceJSON: currentRRuleJSON
        )

        validationError = validation.errorMessage
        return validation.isValid && !scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func saveSchedule() {
        Task {
            if isCreating {
                await scheduleViewModel.createSchedule(
                    routineId: routineId,
                    name: scheduleName.trimmingCharacters(in: .whitespacesAndNewlines),
                    recurrenceJSON: currentRRuleJSON,
                    dtstart: startDate,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    enabled: enabled
                )
            } else if let schedule = schedule {
                var updatedSchedule = schedule
                updatedSchedule.name = scheduleName.trimmingCharacters(in: .whitespacesAndNewlines)
                updatedSchedule.recurrenceJSON = currentRRuleJSON
                updatedSchedule.dtstart = startDate
                updatedSchedule.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                updatedSchedule.enabled = enabled

                await scheduleViewModel.updateSchedule(updatedSchedule)
            }

            onDismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    ScheduleEditView(
        routineId: "preview-routine",
        scheduleViewModel: ScheduleViewModel(),
        isCreating: true
    ) {
        // Dismiss action
    }
    .frame(width: 600, height: 700)
}