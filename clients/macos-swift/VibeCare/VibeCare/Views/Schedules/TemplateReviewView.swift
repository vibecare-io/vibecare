import SwiftUI

struct TemplateReviewView: View {
    let template: RoutineScheduleTemplate
    let routineName: String
    let scheduleName: String
    let scheduleDescription: String
    let routineIcon: String
    let routineColor: String
    let times: [Date]
    let actions: [ActionTemplate]

    @State private var isCreating = false
    @State private var creationSuccess = false

    let onBack: () -> Void
    let onCreate: () async -> Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            if creationSuccess {
                successView
            } else {
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Summary card
                        summaryCard

                        Divider()

                        // Routine preview
                        routinePreview

                        Divider()

                        // Schedule preview
                        schedulePreview

                        Divider()

                        // Actions preview
                        actionsPreview
                    }
                    .padding(20)
                }

                Divider()

                // Footer
                footerView
            }
        }
        .frame(minWidth: 700, minHeight: 600)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review & Create")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Confirm everything looks good before creating")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        HStack(spacing: 20) {
            // Large icon - show backend SVG icon
            TemplateIconView(
                iconId: routineIcon,
                backgroundColor: Color(routineColor).opacity(0.15),
                size: 80
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(routineName)
                    .font(.title3)
                    .fontWeight(.bold)

                Text(scheduleName)
                    .font(.body)
                    .foregroundColor(.secondary)

                if !scheduleDescription.isEmpty {
                    Text(scheduleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Stats
                HStack(spacing: 16) {
                    statBadge(icon: "clock", text: "\(times.count) time\(times.count == 1 ? "" : "s")")
                    statBadge(icon: "bolt.fill", text: "\(actions.count) action\(actions.count == 1 ? "" : "s")")
                }
                .padding(.top, 4)
            }

            Spacer()
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(routineColor).opacity(0.1), Color(routineColor).opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(routineColor).opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Routine Preview

    private var routinePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Routine", icon: "list.bullet")

            VStack(alignment: .leading, spacing: 8) {
                previewRow(label: "Name", value: routineName)
                previewRow(label: "Icon & Color", value: "", customValue: {
                    AnyView(
                        HStack(spacing: 8) {
                            TemplateIconView(
                                iconId: routineIcon,
                                backgroundColor: Color(routineColor).opacity(0.15),
                                size: 24
                            )

                            Text(routineColor.capitalized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    )
                })
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    // MARK: - Schedule Preview

    private var schedulePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Schedule", icon: "calendar")

            VStack(alignment: .leading, spacing: 8) {
                previewRow(label: "Name", value: scheduleName)

                if !scheduleDescription.isEmpty {
                    previewRow(label: "Description", value: scheduleDescription)
                }

                previewRow(label: "Recurrence", value: humanReadableRRule(template.rruleString))

                // Times list
                VStack(alignment: .leading, spacing: 4) {
                    Text("Times")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(times.enumerated()), id: \.offset) { index, time in
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text(formatTime(time))
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }

    // MARK: - Actions Preview

    private var actionsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Actions (\(actions.count))", icon: "bolt.fill")

            if actions.isEmpty {
                Text("No actions configured")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        actionPreviewRow(action: action, index: index + 1)
                    }
                }
            }
        }
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Success animation
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
            }
            .scaleEffect(creationSuccess ? 1.0 : 0.5)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: creationSuccess)

            VStack(spacing: 12) {
                Text("Success!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Your routine and schedule have been created")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String) -> some View {
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

    // MARK: - Preview Row

    private func previewRow(label: String, value: String, customValue: (() -> AnyView)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if let customValue = customValue {
                customValue()
            } else {
                Text(value)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Action Preview Row

    private func actionPreviewRow(action: ActionTemplate, index: Int) -> some View {
        HStack(spacing: 12) {
            // Index badge
            Text("\(index)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            // Action icon
            Image(systemName: actionIconName(action.type))
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)

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
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Stat Badge

    private func statBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)

            Text(text)
                .font(.caption)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Back") {
                onBack()
            }
            .disabled(isCreating)

            Spacer()

            if isCreating {
                ProgressView()
                    .scaleEffect(0.8)
                    .padding(.trailing, 8)

                Text("Creating...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Button("Create Routine & Schedule") {
                    Task {
                        isCreating = true
                        let success = await onCreate()
                        if success {
                            withAnimation {
                                creationSuccess = true
                            }
                        }
                        isCreating = false
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func humanReadableRRule(_ rrule: String) -> String {
        if rrule.contains("FREQ=DAILY") {
            return "Every day"
        } else if rrule.contains("FREQ=WEEKLY") {
            if rrule.contains("BYDAY=MO,TU,WE,TH,FR") {
                return "Every weekday (Mon-Fri)"
            } else if let dayMatch = rrule.range(of: "BYDAY=([A-Z,]+)", options: .regularExpression) {
                let days = String(rrule[dayMatch]).replacingOccurrences(of: "BYDAY=", with: "")
                return "Every week on \(days)"
            }
            return "Every week"
        } else if rrule.contains("FREQ=MONTHLY") {
            if rrule.contains("INTERVAL=3") {
                return "Every 3 months (quarterly)"
            }
            if let day = rrule.range(of: "BYMONTHDAY=(\\d+)", options: .regularExpression) {
                let dayNum = String(rrule[day]).replacingOccurrences(of: "BYMONTHDAY=", with: "")
                return "Monthly on day \(dayNum)"
            }
            return "Every month"
        } else if rrule.contains("FREQ=YEARLY") {
            return "Once a year"
        } else if rrule.contains("FREQ=HOURLY") {
            if let interval = rrule.range(of: "INTERVAL=(\\d+)", options: .regularExpression) {
                let intervalStr = String(rrule[interval]).replacingOccurrences(of: "INTERVAL=", with: "")
                return "Every \(intervalStr) hours"
            }
            return "Every hour"
        }
        return "Custom schedule"
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
}

// MARK: - Preview

#Preview {
    let template = RoutineScheduleTemplate.allTemplates.first ?? RoutineScheduleTemplate(
        id: "preview",
        category: .daily,
        routineName: "Preview Routine",
        routineDescription: "Preview description",
        routineIcon: "star.fill",
        routineColor: "blue",
        scheduleName: "Preview Schedule",
        scheduleDescription: "Preview schedule description",
        rruleString: "FREQ=DAILY",
        defaultTimes: [TimeComponents(hour: 9, minute: 0)]
    )

    TemplateReviewView(
        template: template,
        routineName: template.routineName,
        scheduleName: template.scheduleName,
        scheduleDescription: template.scheduleDescription,
        routineIcon: template.routineIcon,
        routineColor: template.routineColor,
        times: template.defaultTimes.map { $0.toDate() },
        actions: template.suggestedActions,
        onBack: {},
        onCreate: {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        }
    )
}
