import SwiftUI

struct ScheduleRowView: View {
    let schedule: Schedule
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @State private var showActionMenu = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(schedule.enabled ? .green : .orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Title and status
                HStack {
                    Text(schedule.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    // Status tag
                    scheduleStatusTag
                }

                // Recurrence description
                Text(schedule.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Next execution and notes
                HStack {
                    // Next execution time
                    if let nextExecution = schedule.nextExecution {
                        Label(
                            "Next: \(nextExecution, style: .relative)",
                            systemImage: "clock"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else {
                        Label(
                            "No upcoming executions",
                            systemImage: "clock.badge.xmark"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Notes indicator
                    if !schedule.notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Action buttons (visible on hover)
            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        onToggle()
                    } label: {
                        Image(systemName: schedule.enabled ? "pause.circle" : "play.circle")
                            .foregroundColor(schedule.enabled ? .orange : .green)
                    }
                    .buttonStyle(.plain)
                    .help(schedule.enabled ? "Disable schedule" : "Enable schedule")

                    Menu {
                        Button("Edit") {
                            onEdit()
                        }
                        Button("Duplicate") {
                            // TODO: Implement duplicate functionality
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
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(schedule.enabled ? Color.clear : Color.orange.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Schedule Status Tag

    private var scheduleStatusTag: some View {
        Group {
            switch schedule.status {
            case .scheduled:
                statusTag(text: "Scheduled", color: .blue, icon: "clock")
            case .upcoming:
                statusTag(text: "Upcoming", color: .orange, icon: "clock.badge.exclamationmark")
            case .overdue:
                statusTag(text: "Overdue", color: .red, icon: "clock.badge.xmark")
            case .disabled:
                statusTag(text: "Disabled", color: .gray, icon: "pause.circle")
            case .noSchedule:
                statusTag(text: "No Schedule", color: .gray, icon: "clock.arrow.circlepath")
            }
        }
    }

    private func statusTag(text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
}

// MARK: - Simplified Schedule Row for Lists

struct ScheduleRowSimpleView: View {
    let schedule: Schedule
    let showSyncStatus: Bool
    let isPendingDeletion: Bool
    let onToggle: (() -> Void)?

    init(
        schedule: Schedule,
        showSyncStatus: Bool = false,
        isPendingDeletion: Bool = false,
        onToggle: (() -> Void)? = nil
    ) {
        self.schedule = schedule
        self.showSyncStatus = showSyncStatus
        self.isPendingDeletion = isPendingDeletion
        self.onToggle = onToggle
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(isPendingDeletion ? .red.opacity(0.5) : (schedule.enabled ? .green : .orange))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(schedule.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isPendingDeletion ? .secondary : .primary)
                        .strikethrough(isPendingDeletion, color: .secondary)

                    Spacer()

                    // Sync status tag (only for pending deletion items)
                    if showSyncStatus && isPendingDeletion {
                        Text("Pending Deletion")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .clipShape(Capsule())
                    }
                }

                Text(schedule.displayName)
                    .font(.caption)
                    .foregroundColor(isPendingDeletion ? .secondary.opacity(0.7) : .secondary)

                if let nextExecution = schedule.nextExecution, !isPendingDeletion {
                    Text("Next: \(nextExecution, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !isPendingDeletion, let onToggle = onToggle {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: schedule.enabled ? "pause.circle" : "play.circle")
                        .foregroundColor(schedule.enabled ? .orange : .green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .opacity(isPendingDeletion ? 0.7 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        ScheduleRowView(
            schedule: Schedule.example(routineId: "preview-routine"),
            onEdit: {},
            onDelete: {},
            onToggle: {}
        )

        ScheduleRowSimpleView(
            schedule: Schedule.example(routineId: "preview-routine")
        )

        ScheduleRowSimpleView(
            schedule: Schedule.example(routineId: "preview-routine"),
            showSyncStatus: true,
            isPendingDeletion: true
        )
    }
    .padding()
    .frame(width: 400)
}