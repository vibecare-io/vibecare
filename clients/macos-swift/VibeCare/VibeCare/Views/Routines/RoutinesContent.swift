import SwiftUI

struct RoutineListView: View {
    @ObservedObject var viewModel: RoutineViewModel
    let searchText: String
    @Binding var selectedId: String?

    @State private var hoveredRoutineId: String?
    @State private var showDeleteAlert = false
    @State private var routineToDelete: Routine?

    var filteredRoutines: [Routine] {
        viewModel.filteredRoutines(searchText: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with counts
            headerView

            // Routine list
            if filteredRoutines.isEmpty {
                emptyStateView
            } else {
                routineListContent
            }
        }
        .alert("Delete Routine", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let routine = routineToDelete {
                    Task {
                        await viewModel.deleteRoutine(routine)
                    }
                }
            }
        } message: {
            if let routine = routineToDelete {
                Text("Are you sure you want to delete '\(routine.name)'? This action cannot be undone.")
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(filteredRoutines.count) routine\(filteredRoutines.count != 1 ? "s" : "")")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }

            Spacer()

            // Status indicators
            HStack(spacing: 12) {
                StatusIndicator(
                    count: filteredRoutines.filter { $0.enabled }.count,
                    label: "Active",
                    color: .green
                )

                StatusIndicator(
                    count: filteredRoutines.filter { !$0.enabled }.count,
                    label: "Disabled",
                    color: .orange
                )
            }

            // Create new routine button
            FloatingActionButtonSmall(systemImage: "plus") {
                createNewRoutine()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("No Routines")
                    .font(.title3)
                    .fontWeight(.medium)

                Text(searchText.isEmpty ?
                     "Create your first routine to get started with VibeCare" :
                     "No routines match your search")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if searchText.isEmpty {
                Button("Create Routine") {
                    createNewRoutine()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Routine List Content

    private var routineListContent: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredRoutines) { routine in
                    RoutineRowView(
                        routine: routine,
                        isSelected: selectedId == routine.id,
                        isHovered: hoveredRoutineId == routine.id,
                        onSelect: {
                            selectedId = routine.id
                        },
                        onToggleEnabled: {
                            Task {
                                await viewModel.toggleRoutineEnabled(routine)
                            }
                        },
                        onDelete: {
                            routineToDelete = routine
                            showDeleteAlert = true
                        },
                        onDuplicate: {
                            Task {
                                await viewModel.duplicateRoutine(routine)
                            }
                        },
                        onTest: {
                            Task {
                                await viewModel.testRoutine(routine)
                            }
                        }
                    )
                    .onHover { isHovered in
                        hoveredRoutineId = isHovered ? routine.id : nil
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Routine Row View

struct RoutineRowView: View {
    let routine: Routine
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onTest: () -> Void

    @State private var showActionMenu = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(routine.enabled ? .green : .orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                // Title and category
                HStack {
                    Text(routine.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer()

                    // Category tag
                    if !routine.category.isEmpty {
                        Text(routine.category)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }

                // Description
                if !routine.description.isEmpty {
                    Text(routine.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Action count and last execution
                HStack {
                    Label("\(routine.actionIds.count) action\(routine.actionIds.count != 1 ? "s" : "")",
                          systemImage: "bolt.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let lastExecution = routine.lastExecutedAt {
                        Text("Last: \(lastExecution, style: .relative)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Never executed")
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
                        Image(systemName: routine.enabled ? "pause.circle" : "play.circle")
                            .foregroundColor(routine.enabled ? .orange : .green)
                    }
                    .buttonStyle(.plain)
                    .help(routine.enabled ? "Disable routine" : "Enable routine")

                    Button {
                        onTest()
                    } label: {
                        Image(systemName: "play.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Test routine")

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
}

// MARK: - Preview

#Preview {
    RoutineListView(
        viewModel: RoutineViewModel(),
        searchText: "",
        selectedId: .constant(nil)
    )
    .frame(width: 400, height: 600)
}

// MARK: - Actions

extension RoutineListView {
    private func createNewRoutine() {
        // Set selectedId to a special "new" value to trigger creation mode
        selectedId = "new-routine"
    }
}