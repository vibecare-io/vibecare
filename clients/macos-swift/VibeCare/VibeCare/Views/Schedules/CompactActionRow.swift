import SwiftUI

struct CompactActionRow: View {
    let action: Action
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Action type icon
            Image(systemName: action.type.iconName)
                .font(.title3)
                .foregroundColor(colorForType(action.type))
                .frame(width: 24)

            // Action name and type
            VStack(alignment: .leading, spacing: 2) {
                Text(action.type.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let param = primaryParameter {
                    Text(param)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action buttons (show on hover)
            if isHovered {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Edit action")

                    Button(action: { showDeleteConfirmation = true }) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title3)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete action")
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color(NSColor.controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(colorForType(action.type).opacity(0.2), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            // Double-click to edit
            onEdit()
        }
        .alert("Delete Action", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Are you sure you want to delete this \(action.type.displayName) action?")
        }
    }

    private var primaryParameter: String? {
        switch action.type {
        case .notification:
            return action.parameters["body"] ?? action.parameters["title"]
        case .openLink:
            return action.parameters["url"]
        case .sendEmail:
            return action.parameters["to"]
        case .runScript:
            if let script = action.parameters["script"] {
                return script.components(separatedBy: "\n").first
            }
            return nil
        case .playSound:
            return action.parameters["sound_file"]
        case .systemCommand:
            return action.parameters["command"]
        case .apiCall:
            return action.parameters["url"]
        case .logEntry:
            return action.parameters["message"]
        }
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

#Preview {
    VStack(spacing: 8) {
        CompactActionRow(
            action: Action(
                id: "1",
                profileId: "test",
                type: .notification,
                name: "Test Notification",
                description: "",
                parameters: ["title": "Test", "body": "This is a test notification"],
                enabled: true
            ),
            onEdit: {},
            onDelete: {}
        )

        CompactActionRow(
            action: Action(
                id: "2",
                profileId: "test",
                type: .openLink,
                name: "Test Link",
                description: "",
                parameters: ["url": "https://example.com"],
                enabled: true
            ),
            onEdit: {},
            onDelete: {}
        )

        CompactActionRow(
            action: Action(
                id: "3",
                profileId: "test",
                type: .sendEmail,
                name: "Test Email",
                description: "",
                parameters: ["to": "test@example.com", "subject": "Test Email"],
                enabled: true
            ),
            onEdit: {},
            onDelete: {}
        )
    }
    .padding()
    .frame(width: 400)
}
