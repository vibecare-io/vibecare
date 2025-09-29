import SwiftUI

struct ActionDetailView: View {
    let action: Action?
    let viewModel: ActionViewModel

    var body: some View {
        if let action = action {
            actionDetailContent(for: action)
        } else {
            emptyStateView
        }
    }

    private func actionDetailContent(for action: Action) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actionHeader(for: action)
                Divider()
                actionDetails(for: action)
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Action Details")
    }

    private func actionHeader(for action: Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: action.type.iconName)
                    .font(.title)
                    .foregroundColor(.blue)

                VStack(alignment: .leading) {
                    Text(action.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(action.type.displayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .clipShape(Capsule())
                }

                Spacer()
            }
        }
    }

    private func actionDetails(for action: Action) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailRow(title: "Type", value: action.type.displayName)
            DetailRow(title: "Description", value: action.description.isEmpty ? "No description" : action.description)
            DetailRow(title: "Created", value: DateFormatter.localizedString(from: action.createdAt, dateStyle: .medium, timeStyle: .short))

            if !action.parameters.isEmpty {
                Text("Parameters")
                    .font(.headline)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(action.parameters.keys.sorted()), id: \.self) { key in
                        if let value = action.parameters[key] {
                            DetailRow(title: key, value: value)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        EmptyStateView(
            title: "No Action Selected",
            subtitle: "Select an action from the library to view its details",
            systemImage: "bolt.circle"
        )
    }
}


#Preview {
    ActionDetailView(
        action: Action(
            profileId: "preview",
            type: .notification,
            name: "Eye Care Reminder",
            description: "Reminds to look at something 20 feet away for 20 seconds"
        ),
        viewModel: ActionViewModel()
    )
}