import SwiftUI

struct RoutineDetailView: View {
    let routine: Routine
    @ObservedObject var viewModel: RoutineViewModel

    @State private var showEditSheet = false
    @State private var showDeleteAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Description
                if !routine.description.isEmpty {
                    descriptionSection
                }

                // Metadata
                metadataSection

                // Actions
                actionsSection

                // Execution History
                executionHistorySection

                Spacer(minLength: 40)
            }
            .padding(24)
        }
        .navigationTitle(routine.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.testRoutine(routine)
                    }
                } label: {
                    Label("Test", systemImage: "play.circle")
                }
                .help("Test this routine")

                Button {
                    showEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Edit routine")

                Menu {
                    Button {
                        Task {
                            await viewModel.duplicateRoutine(routine)
                        }
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }

                    Button {
                        Task {
                            await viewModel.toggleRoutineEnabled(routine)
                        }
                    } label: {
                        Label(routine.enabled ? "Disable" : "Enable",
                              systemImage: routine.enabled ? "pause.circle" : "play.circle")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            RoutineFormView(viewModel: viewModel, editingRoutine: routine)
        }
        .alert("Delete Routine", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteRoutine(routine)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(routine.name)'? This action cannot be undone.")
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(routine.enabled ? .green : .orange)
                        .frame(width: 12, height: 12)

                    Text(routine.enabled ? "Active" : "Disabled")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(routine.enabled ? .green : .orange)
                }

                Spacer()

                // Category tag
                if !routine.category.isEmpty {
                    Text(routine.category)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
            }

            // Tags
            if !routine.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(routine.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundColor(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)

            Text(routine.description)
                .font(.body)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                MetadataItem(
                    title: "Actions",
                    value: "\(routine.actionIds.count)",
                    icon: "bolt.circle"
                )

                MetadataItem(
                    title: "Created",
                    value: routine.createdAt.formatted(date: .abbreviated, time: .omitted),
                    icon: "calendar"
                )

                MetadataItem(
                    title: "Last Updated",
                    value: routine.updatedAt.formatted(date: .abbreviated, time: .omitted),
                    icon: "clock"
                )

                MetadataItem(
                    title: "Last Executed",
                    value: routine.lastExecutedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never",
                    icon: "play.circle"
                )
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions (\(routine.actionIds.count))")
                .font(.headline)

            if routine.actionIds.isEmpty {
                EmptyStateView(
                    title: "No Actions",
                    subtitle: "Add actions to this routine to define what happens when it executes",
                    systemImage: "bolt.circle",
                    actionTitle: "Add Action"
                ) {
                    showEditSheet = true
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(routine.actionIds.indices, id: \.self) { index in
                        ActionPreviewCard(
                            actionId: routine.actionIds[index],
                            index: index + 1
                        )
                    }
                }
            }
        }
    }

    // MARK: - Execution History Section

    private var executionHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Executions")
                    .font(.headline)

                Spacer()

                Button("View All") {
                    // Navigate to full execution history
                }
                .font(.caption)
            }

            // This would show actual execution logs
            // For now, show placeholder
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    ExecutionHistoryRow(
                        timestamp: Date().addingTimeInterval(TimeInterval(-index * 3600)),
                        success: index != 1,
                        notes: index == 1 ? "Action failed: Network timeout" : "Completed successfully"
                    )
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct MetadataItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct ActionPreviewCard: View {
    let actionId: String
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            // Step number
            Text("\(index)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Sample Action \(index)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Action description would go here")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "bolt.circle.fill")
                .foregroundColor(.accentColor)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ExecutionHistoryRow: View {
    let timestamp: Date
    let success: Bool
    let notes: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(notes)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        RoutineDetailView(
            routine: Routine.samples(for: "sample", with: []).first!,
            viewModel: RoutineViewModel()
        )
    }
    .frame(width: 600, height: 800)
}