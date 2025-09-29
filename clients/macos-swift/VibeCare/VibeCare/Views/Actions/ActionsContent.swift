import SwiftUI

struct ActionLibraryView: View {
    @ObservedObject var viewModel: ActionViewModel
    let searchText: String
    @Binding var selectedId: String?

    @State private var hoveredActionId: String?

    var filteredActions: [Action] {
        if searchText.isEmpty {
            return viewModel.actions
        } else {
            return viewModel.actions.filter { action in
                action.name.localizedCaseInsensitiveContains(searchText) ||
                action.description.localizedCaseInsensitiveContains(searchText) ||
                action.type.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        VStack {
            if filteredActions.isEmpty {
                EmptyStateView(
                    title: searchText.isEmpty ? "No Actions" : "No Matching Actions",
                    subtitle: searchText.isEmpty ? "Create actions to build powerful routines" : "No actions match your search",
                    systemImage: "bolt.circle"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200), spacing: 16)
                    ], spacing: 16) {
                        ForEach(filteredActions) { action in
                            ActionCard(
                                action: action,
                                isSelected: selectedId == action.id,
                                isHovered: hoveredActionId == action.id,
                                onSelect: {
                                    selectedId = action.id
                                }
                            )
                            .onHover { isHovered in
                                hoveredActionId = isHovered ? action.id : nil
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Action Library")
    }
}

struct ActionCard: View {
    let action: Action
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.secondary.opacity(0.05) : Color(NSColor.controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

#Preview {
    ActionLibraryView(
        viewModel: ActionViewModel(),
        searchText: "",
        selectedId: .constant(nil)
    )
}