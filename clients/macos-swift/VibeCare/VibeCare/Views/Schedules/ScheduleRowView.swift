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

    init(
        schedule: Schedule,
        isSelected: Bool,
        isHovered: Bool,
        onSelect: @escaping () -> Void,
        onToggleEnabled: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onTest: @escaping () -> Void
    ) {
        self.schedule = schedule
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.onSelect = onSelect
        self.onToggleEnabled = onToggleEnabled
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        self.onTest = onTest
    }

    @State private var showActionMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(schedule.enabled ? .green : .orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Title and routine context
                HStack {
                    Text(schedule.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    // Routine context tag
                    Text("Routine: \(routineDisplayName)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }

                // Recurrence description
                if !schedule.notes.isEmpty {
                    Text(schedule.notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Schedule details and execution info
                HStack {
                    Label(schedule.displayName, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let nextExecution = schedule.nextExecution {
                        Text("Next: \(nextExecution, style: .relative)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No upcoming execution")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Action buttons (visible on hover or selection)
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

    // MARK: - Helper Properties

    private var routineDisplayName: String {
        // TODO: Get actual routine name from routine ID
        // For now, return a truncated routine ID
        return String(schedule.routineId.prefix(8))
    }

}

// MARK: - Simplified Schedule Row for Lists

struct ScheduleRowSimpleView: View {
    let schedule: Schedule
    let onToggle: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    init(
        schedule: Schedule,
        onToggle: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.schedule = schedule
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(schedule.enabled ? .green : .orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(schedule.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let nextExecution = schedule.nextExecution {
                    Text("Next: \(nextExecution, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
            onTest: {}
        )

        ScheduleRowView(
            schedule: Schedule.example(routineId: "preview-routine"),
            isSelected: true,
            isHovered: true,
            onSelect: {},
            onToggleEnabled: {},
            onDelete: {},
            onDuplicate: {},
            onTest: {}
        )

        ScheduleRowSimpleView(
            schedule: Schedule.example(routineId: "preview-routine"),
            onToggle: {},
            onEdit: {},
            onDelete: {}
        )
    }
    .padding()
    .frame(width: 400)
}