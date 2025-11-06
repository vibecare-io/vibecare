import SwiftUI

/// Quick action buttons for schedule rows that appear on hover
/// Provides Enable/Disable toggle, Quick Edit, and More menu (Duplicate, Delete)
struct ScheduleQuickActions: View {
    let schedule: Schedule
    let isVisible: Bool
    let onToggleEnabled: () -> Void
    let onQuickEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 4) {
            // Enable/Disable Toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    onToggleEnabled()
                }
            } label: {
                Image(systemName: schedule.enabled ? "pause.circle.fill" : "play.circle.fill")
                    .foregroundStyle(schedule.enabled ? .orange : .green)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help(schedule.enabled ? "Disable schedule" : "Enable schedule")

            // Quick Edit Button
            Button {
                onQuickEdit()
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.blue)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .help("Edit schedule")

            // More Menu
            Menu {
                Button {
                    onDuplicate()
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }

                Button {
                    onQuickEdit()
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .confirmationDialog(
                "Delete Schedule",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete '\(schedule.name)'? This action cannot be undone.")
            }
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isVisible)
    }
}

// MARK: - Preview

#Preview("Quick Actions - Enabled Schedule") {
    VStack(spacing: 20) {
        HStack {
            Text("Hover to see actions:")
            Spacer()
            ScheduleQuickActions(
                schedule: Schedule.example(profileId: "test-profile", routineId: "test-routine"),
                isVisible: true,
                onToggleEnabled: { print("Toggle enabled") },
                onQuickEdit: { print("Quick edit") },
                onDuplicate: { print("Duplicate") },
                onDelete: { print("Delete") }
            )
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)

        HStack {
            Text("Hidden state:")
            Spacer()
            ScheduleQuickActions(
                schedule: Schedule.example(profileId: "test-profile", routineId: "test-routine"),
                isVisible: false,
                onToggleEnabled: {},
                onQuickEdit: {},
                onDuplicate: {},
                onDelete: {}
            )
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    .padding()
    .frame(width: 400)
}

#Preview("Quick Actions - Disabled Schedule") {
    @Previewable @State var disabledSchedule = {
        var schedule = Schedule.example(profileId: "test-profile", routineId: "test-routine")
        schedule.enabled = false
        return schedule
    }()

    HStack {
        Text("Disabled schedule:")
        Spacer()
        ScheduleQuickActions(
            schedule: disabledSchedule,
            isVisible: true,
            onToggleEnabled: { print("Toggle enabled") },
            onQuickEdit: { print("Quick edit") },
            onDuplicate: { print("Duplicate") },
            onDelete: { print("Delete") }
        )
    }
    .padding()
    .background(Color(NSColor.controlBackgroundColor))
    .cornerRadius(8)
    .frame(width: 400)
}
