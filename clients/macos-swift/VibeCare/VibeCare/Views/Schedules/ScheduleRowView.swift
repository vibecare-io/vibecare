import SwiftUI

struct ScheduleRowView: View {
    let schedule: Schedule
    let isSelected: Bool
    let isHovered: Bool
    let showSyncStatus: Bool
    let isPendingDeletion: Bool
    let syncStatus: SyncStatus?
    let retryCount: Int
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onTest: () -> Void

    init(
        schedule: Schedule,
        isSelected: Bool,
        isHovered: Bool,
        showSyncStatus: Bool = false,
        isPendingDeletion: Bool = false,
        syncStatus: SyncStatus? = nil,
        retryCount: Int = 0,
        onSelect: @escaping () -> Void,
        onToggleEnabled: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onTest: @escaping () -> Void
    ) {
        self.schedule = schedule
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.showSyncStatus = showSyncStatus
        self.isPendingDeletion = isPendingDeletion
        self.syncStatus = syncStatus
        self.retryCount = retryCount
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
                .fill(isPendingDeletion ? .red.opacity(0.5) : (schedule.enabled ? .green : .orange))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Title and routine context
                HStack {
                    Text(schedule.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(isPendingDeletion ? .secondary : .primary)
                        .strikethrough(isPendingDeletion, color: .secondary)

                    Spacer()

                    // Status tags
                    HStack(spacing: 4) {
                        // Sync status tags
                        if showSyncStatus {
                            syncStatusTag
                        }

                        // Routine context tag
                        Text("Routine: \(routineDisplayName)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isPendingDeletion ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.1))
                            .foregroundColor(isPendingDeletion ? .secondary : .accentColor)
                            .clipShape(Capsule())
                    }
                }

                // Recurrence description
                if !schedule.notes.isEmpty {
                    Text(schedule.notes)
                        .font(.caption)
                        .foregroundColor(isPendingDeletion ? .secondary.opacity(0.7) : .secondary)
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

            // Action buttons (visible on hover or selection, disabled for pending deletion)
            if (isHovered || isSelected) && !isPendingDeletion {
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
                        Image(systemName: "play.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Test schedule")

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
            } else if isPendingDeletion && (isHovered || isSelected) {
                // Show retry count for pending deletion
                if retryCount > 0 {
                    Text("Retry \(retryCount)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fontWeight(.medium)
                } else {
                    Text("Syncing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPendingDeletion
                      ? Color.red.opacity(0.05)
                      : (isSelected ? Color.accentColor.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPendingDeletion
                        ? Color.red.opacity(0.2)
                        : (isSelected ? Color.accentColor : Color.clear), lineWidth: 1)
        )
        .opacity(isPendingDeletion ? 0.7 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isPendingDeletion {
                onSelect()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    // MARK: - Helper Properties

    @ViewBuilder
    private var syncStatusTag: some View {
        if let syncStatus = syncStatus {
            switch syncStatus {
            case .pendingDelete:
                HStack(spacing: 2) {
                    Text("Pending Deletion")
                    if retryCount > 0 {
                        Text("(\(retryCount))")
                            .fontWeight(.bold)
                    }
                }
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
                .clipShape(Capsule())

            case .syncFailed:
                HStack(spacing: 2) {
                    Text("Sync Failed")
                    if retryCount > 0 {
                        Text("(\(retryCount))")
                            .fontWeight(.bold)
                    }
                }
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
                .clipShape(Capsule())

            case .pendingSync:
                Text("Pending Sync")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())

            case .conflict:
                Text("Conflict")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.1))
                    .foregroundColor(.purple)
                    .clipShape(Capsule())

            case .localOnly:
                Text("Local Only")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())

            case .synced:
                // Don't show tag for successfully synced items to reduce clutter
                EmptyView()
            }
        }
    }

    private var routineDisplayName: String {
        // TODO: Get actual routine name from routine ID
        // For now, return a truncated routine ID
        return String(schedule.routineId.prefix(8))
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

        ScheduleRowView(
            schedule: Schedule.example(routineId: "preview-routine"),
            isSelected: false,
            isHovered: false,
            showSyncStatus: true,
            isPendingDeletion: true,
            onSelect: {},
            onToggleEnabled: {},
            onDelete: {},
            onDuplicate: {},
            onTest: {}
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