import SwiftUI

struct ActionLibraryView: View {
    @ObservedObject var viewModel: ActionViewModel
    let searchText: String
    @Binding var showInspector: Bool

    var body: some View {
        VStack {
            if viewModel.actions.isEmpty {
                EmptyStateView(
                    title: "No Actions",
                    subtitle: "Create actions to build powerful routines",
                    systemImage: "bolt.circle"
                )
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 200), spacing: 16)
                ], spacing: 16) {
                    ForEach(viewModel.actions) { action in
                        ActionCard(action: action)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Action Library")
    }
}

struct ActionCard: View {
    let action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: action.type.iconName)
                    .foregroundColor(Color(action.type.color))
                    .font(.title2)

                Spacer()

                Text(action.type.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(action.type.color).opacity(0.1))
                    .foregroundColor(Color(action.type.color))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(action.name)
                    .font(.headline)
                    .lineLimit(1)

                if !action.description.isEmpty {
                    Text(action.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

#Preview {
    ActionLibraryView(
        viewModel: ActionViewModel(),
        searchText: "",
        showInspector: .constant(false)
    )
}