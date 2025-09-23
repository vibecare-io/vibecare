import SwiftUI

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
                .opacity(0.6)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: 300)
        .padding(40)
    }
}

#Preview {
    VStack(spacing: 40) {
        EmptyStateView(
            title: "No Routines",
            subtitle: "Create your first routine to get started with VibeCare",
            systemImage: "list.bullet.circle",
            actionTitle: "Create Routine"
        ) {
            print("Create routine tapped")
        }

        EmptyStateView(
            title: "No Selection",
            subtitle: "Select a routine from the list to view its details",
            systemImage: "checkmark.circle"
        )
    }
    .frame(width: 400, height: 600)
}