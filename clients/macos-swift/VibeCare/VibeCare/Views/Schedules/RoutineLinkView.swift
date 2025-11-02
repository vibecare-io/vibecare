import SwiftUI

/// Clickable routine link view for schedules
/// Shows routine name with icon/status and navigates to routine detail on click
struct RoutineLinkView: View {
    let routineId: String
    let routine: Routine?
    let onNavigate: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onNavigate(routineId)
        } label: {
            HStack(spacing: 6) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Routine icon
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Routine name
                Text(displayName)
                    .font(.subheadline)
                    .foregroundStyle(isHovered ? .blue : .primary)
                    .lineLimit(1)

                // Navigation chevron
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("Navigate to routine: \(displayName)")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Helper Properties

    private var displayName: String {
        routine?.name ?? "Unknown Routine"
    }

    private var iconName: String {
        routine?.iconName ?? "questionmark.circle"
    }

    private var statusColor: Color {
        guard let routine = routine else {
            return .gray
        }
        return routine.enabled ? .green : .orange
    }
}

// MARK: - Compact Variant

/// Compact routine link for inline use (no navigation, just display)
struct RoutineLinkCompact: View {
    let routineId: String
    let routine: Routine?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: routine?.iconName ?? "circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(routine?.name ?? String(routineId.prefix(8)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Preview

#Preview("Routine Link View") {
    VStack(spacing: 20) {
        Text("Routine Link Examples")
            .font(.headline)

        // With routine loaded
        RoutineLinkView(
            routineId: "routine-1",
            routine: Routine(
                id: "routine-1",
                profileId: "profile-1",
                name: "Morning Meditation",
                enabled: true
            ),
            onNavigate: { id in
                print("Navigate to routine: \(id)")
            }
        )

        // Disabled routine
        RoutineLinkView(
            routineId: "routine-2",
            routine: Routine(
                id: "routine-2",
                profileId: "profile-1",
                name: "Evening Workout",
                enabled: false
            ),
            onNavigate: { id in
                print("Navigate to routine: \(id)")
            }
        )

        // Routine not loaded
        RoutineLinkView(
            routineId: "routine-3",
            routine: nil,
            onNavigate: { id in
                print("Navigate to routine: \(id)")
            }
        )

        Divider()

        Text("Compact Variant")
            .font(.headline)

        HStack {
            RoutineLinkCompact(
                routineId: "routine-1",
                routine: Routine(
                    id: "routine-1",
                    profileId: "profile-1",
                    name: "Morning Meditation"
                )
            )

            RoutineLinkCompact(
                routineId: "routine-2",
                routine: nil
            )
        }
    }
    .padding()
    .frame(width: 400)
}

#Preview("In Context - Schedule Row") {
    VStack(spacing: 12) {
        Text("Schedule with Routine Link")
            .font(.headline)

        VStack(alignment: .leading, spacing: 8) {
            Text("Every 20 minutes")
                .font(.body)
                .fontWeight(.medium)

            HStack {
                Text("Routine:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                RoutineLinkView(
                    routineId: "routine-1",
                    routine: Routine(
                        id: "routine-1",
                        profileId: "profile-1",
                        name: "Focus Session",
                        enabled: true
                    ),
                    onNavigate: { id in
                        print("Navigate to: \(id)")
                    }
                )

                Spacer()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    .padding()
    .frame(width: 400)
}
