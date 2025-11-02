import SwiftUI

struct ScheduleRowView: View {
    let schedule: Schedule
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onTest: () -> Void

    // Optional routine name for context (passed from parent)
    var routineName: String?

    init(
        schedule: Schedule,
        isSelected: Bool,
        isHovered: Bool,
        onSelect: @escaping () -> Void,
        onToggleEnabled: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onTest: @escaping () -> Void,
        routineName: String? = nil
    ) {
        self.schedule = schedule
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.onSelect = onSelect
        self.onToggleEnabled = onToggleEnabled
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        self.onTest = onTest
        self.routineName = routineName
    }

    @State private var showActionMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator - color-coded based on schedule state
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Title and routine context
                HStack {
                    Text(schedule.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    // Routine context tag - shows parent routine
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.circle.fill")
                            .font(.caption2)
                        Text(routineDisplayName)
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                }

                // RRule summary - human-readable description
                if let rruleDescription = schedule.parsedRRule?.humanReadableDescription {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(rruleDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Notes (if available)
                if !schedule.notes.isEmpty {
                    Text(schedule.notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Schedule metadata and next execution
                HStack {
                    // Action count
                    if !schedule.actionIDs.isEmpty {
                        Label("\(schedule.actionIDs.count) action\(schedule.actionIDs.count != 1 ? "s" : "")",
                              systemImage: "bolt.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Priority indicator
                    if schedule.priority != .none {
                        HStack(spacing: 2) {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                            Text(schedule.priority.displayName)
                                .font(.caption)
                        }
                        .foregroundColor(priorityColor)
                    }

                    Spacer()

                    // Next run preview
                    nextRunView
                }
            }

            // Hover actions (visible on hover or selection)
            if isHovered || isSelected {
                HStack(spacing: 4) {
                    Button {
                        onToggleEnabled()
                    } label: {
                        Image(systemName: schedule.enabled ? "pause.circle" : "play.circle")
                            .foregroundColor(schedule.enabled ? .orange : .green)
                    }
                    .buttonStyle(.plain)
                    .help(schedule.enabled ? "Disable schedule" : "Enable schedule")

                    Button {
                        onTest()
                    } label: {
                        Image(systemName: "eye.fill")
                            .foregroundColor(.purple)
                    }
                    .buttonStyle(.plain)
                    .help("Preview notification")

                    Menu {
                        Button("Duplicate") {
                            onDuplicate()
                        }
                        Button("Edit") {
                            onSelect()
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            onDelete()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("More actions")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    // MARK: - Subviews

    private var nextRunView: some View {
        Group {
            if !schedule.enabled {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption2)
                    Text("Paused")
                        .font(.caption)
                }
                .foregroundColor(.orange)
            } else if let nextExecution = schedule.nextExecution {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.caption2)
                    Text("Next: \(nextExecution, style: .relative)")
                        .font(.caption)
                }
                .foregroundColor(nextRunColor(for: nextExecution))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                    Text("No upcoming run")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Properties

    private var routineDisplayName: String {
        if let routineName = routineName, !routineName.isEmpty {
            return routineName
        }
        // Fallback to truncated routine ID
        return String(schedule.routineId.prefix(8))
    }

    private var statusColor: Color {
        if !schedule.enabled {
            return .gray
        }

        guard let nextRun = schedule.nextExecution else {
            return .gray
        }

        let now = Date()
        let timeInterval = nextRun.timeIntervalSince(now)

        if timeInterval < 0 {
            // Overdue
            return .red
        } else if timeInterval < 3600 {
            // Upcoming (within 1 hour)
            return .orange
        } else {
            // Scheduled normally
            return .green
        }
    }

    private var priorityColor: Color {
        switch schedule.priority {
        case .none: return .secondary
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private func nextRunColor(for date: Date) -> Color {
        let now = Date()
        let timeInterval = date.timeIntervalSince(now)

        if timeInterval < 0 {
            return .red // Overdue
        } else if timeInterval < 3600 {
            return .orange // Within next hour
        } else {
            return .secondary // Normal
        }
    }
}

// MARK: - Simplified Schedule Row for Lists

struct ScheduleRowSimpleView: View {
    let schedule: Schedule
    let onToggle: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    var routineName: String?

    init(
        schedule: Schedule,
        onToggle: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        routineName: String? = nil
    ) {
        self.schedule = schedule
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.routineName = routineName
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                // Title
                Text(schedule.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                // RRule summary
                if let rruleDescription = schedule.parsedRRule?.humanReadableDescription {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat.circle.fill")
                            .font(.caption2)
                        Text(rruleDescription)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                // Next execution
                if schedule.enabled, let nextExecution = schedule.nextExecution {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text("Next: \(nextExecution, style: .relative)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                } else if !schedule.enabled {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle.fill")
                            .font(.caption2)
                        Text("Paused")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                }
            }

            if isHovered {
                HStack(spacing: 8) {
                    if let onToggle = onToggle {
                        Button {
                            onToggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: schedule.enabled ? "pause.circle" : "play.circle")
                                Text(schedule.enabled ? "Pause" : "Enable")
                                    .font(.caption)
                            }
                            .foregroundColor(schedule.enabled ? .orange : .green)
                        }
                        .buttonStyle(.plain)
                        .help(schedule.enabled ? "Disable schedule" : "Enable schedule")
                    }

                    if let onEdit = onEdit {
                        Button {
                            onEdit()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("Edit")
                                    .font(.caption)
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Edit schedule")
                    }

                    if let onDelete = onDelete {
                        Button {
                            onDelete()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Delete")
                                    .font(.caption)
                            }
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete schedule")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Helper Properties

    private var statusColor: Color {
        if !schedule.enabled {
            return .gray
        }

        guard let nextRun = schedule.nextExecution else {
            return .gray
        }

        let now = Date()
        let timeInterval = nextRun.timeIntervalSince(now)

        if timeInterval < 0 {
            return .red
        } else if timeInterval < 3600 {
            return .orange
        } else {
            return .green
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        ScheduleRowView(
            schedule: Schedule.example(routineId: "preview-routine"),
            isSelected: false,
            isHovered: false,
            onSelect: {},
            onToggleEnabled: {},
            onDelete: {},
            onDuplicate: {},
            onTest: {},
            routineName: "Morning Routine"
        )

        ScheduleRowView(
            schedule: Schedule.example(routineId: "preview-routine"),
            isSelected: true,
            isHovered: true,
            onSelect: {},
            onToggleEnabled: {},
            onDelete: {},
            onDuplicate: {},
            onTest: {},
            routineName: "Evening Routine"
        )

        // Disabled schedule
        ScheduleRowView(
            schedule: {
                var s = Schedule.example(routineId: "preview-routine")
                s.enabled = false
                return s
            }(),
            isSelected: false,
            isHovered: false,
            onSelect: {},
            onToggleEnabled: {},
            onDelete: {},
            onDuplicate: {},
            onTest: {},
            routineName: "Afternoon Routine"
        )

        ScheduleRowSimpleView(
            schedule: Schedule.example(routineId: "preview-routine"),
            onToggle: {},
            onEdit: {},
            onDelete: {},
            routineName: "Test Routine"
        )
    }
    .padding()
    .frame(width: 500)
}
