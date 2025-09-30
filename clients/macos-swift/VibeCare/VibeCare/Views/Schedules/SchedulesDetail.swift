import SwiftUI

struct ScheduleDetailView: View {
    let schedule: Schedule?
    let viewModel: ScheduleViewModel
    let isCreating: Bool
    let onCancel: (() -> Void)?

    @State private var showEditSheet = false
    @State private var showDeleteAlert = false
    @State private var showDuplicateSheet = false
    @State private var isTestingSchedule = false

    init(
        schedule: Schedule?,
        viewModel: ScheduleViewModel,
        isCreating: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        self.schedule = schedule
        self.viewModel = viewModel
        self.isCreating = isCreating
        self.onCancel = onCancel
    }

    var body: some View {
        Group {
            if isCreating {
                scheduleCreationView
            } else if let schedule = schedule {
                scheduleDetailContent(schedule)
            } else {
                EmptyStateView(
                    title: "No Schedule Selected",
                    subtitle: "Select a schedule from the list to view its details",
                    systemImage: "calendar.circle"
                )
            }
        }
        .alert("Delete Schedule", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let schedule = schedule {
                    Task {
                        await viewModel.deleteSchedule(schedule)
                    }
                }
            }
        } message: {
            if let schedule = schedule {
                Text("Are you sure you want to delete '\(schedule.name)'? This action cannot be undone.")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let schedule = schedule {
                ScheduleFormView(viewModel: viewModel, editingSchedule: schedule)
            }
        }
        .sheet(isPresented: $showDuplicateSheet) {
            if let schedule = schedule {
                ScheduleFormView(viewModel: viewModel, duplicatingSchedule: schedule)
            }
        }
    }

    // MARK: - Schedule Creation View

    private var scheduleCreationView: some View {
        ScheduleFormView(
            viewModel: viewModel,
            onCancel: onCancel
        )
    }

    // MARK: - Schedule Detail Content

    private func scheduleDetailContent(_ schedule: Schedule) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Section
                scheduleHeaderSection(schedule)

                Divider()

                // Status Section
                scheduleStatusSection(schedule)

                // Sync Error Section (only for pending deletion or failed sync)
                if shouldShowSyncErrorSection(schedule) {
                    Divider()
                    syncErrorSection(schedule)
                }

                Divider()

                // Timing Section
                scheduleTimingSection(schedule)

                Divider()

                // Routine Context Section
                routineContextSection(schedule)

                Divider()

                // Execution History Section
                executionHistorySection(schedule)

                Divider()

                // Quick Actions Section
                quickActionsSection(schedule)

                Spacer()
            }
            .padding()
        }
        .navigationTitle(schedule.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                scheduleToolbarButtons(schedule)
            }
        }
    }

    // MARK: - Header Section

    private func scheduleHeaderSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(schedule.displayName)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(schedule.enabled ? .green : .orange)
                        .frame(width: 12, height: 12)

                    Text(schedule.enabled ? "Active" : "Disabled")
                        .font(.headline)
                        .foregroundColor(schedule.enabled ? .green : .orange)
                }
            }

            if !schedule.notes.isEmpty {
                Text(schedule.notes)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Status Section

    private func scheduleStatusSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Status")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statusCard("State", value: schedule.enabled ? "Active" : "Disabled", color: schedule.enabled ? .green : .orange)
                statusCard("Sync Status", value: syncStatusText(schedule), color: syncStatusColor(schedule))
            }
        }
    }

    // MARK: - Sync Error Section

    private func shouldShowSyncErrorSection(_ schedule: Schedule) -> Bool {
        let status = viewModel.getSyncStatus(for: schedule.id) ?? .localOnly
        return status == .pendingDelete || status == .syncFailed
    }

    private func syncErrorSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Sync Issues")

            let retryCount = viewModel.getRetryCount(for: schedule.id)
            let errorHistory = viewModel.getSyncErrorHistory(for: schedule.id)

            VStack(spacing: 8) {
                DetailRow(title: "Retry Count", value: "\(retryCount)")

                if !errorHistory.isEmpty {
                    sectionSubHeader("Recent Errors")

                    ForEach(errorHistory.prefix(5)) { syncError in
                        syncErrorCard(syncError)
                    }
                } else {
                    Text("No error details available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func syncErrorCard(_ syncError: SyncError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attempt #\(syncError.retryAttempt)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)

                Spacer()

                Text(syncError.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(syncError.errorMessage)
                .font(.caption)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)

            if let errorCode = syncError.errorCode {
                Text("Error Code: \(errorCode)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sectionSubHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
    }

    // MARK: - Timing Section

    private func scheduleTimingSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Timing")

            VStack(spacing: 8) {
                DetailRow(title: "Start Time", value: schedule.dtstart, formatter: .dateTime)

                if let nextExecution = schedule.nextExecution {
                    DetailRow(title: "Next Execution", value: nextExecution, formatter: .relative)
                } else {
                    DetailRow(title: "Next Execution", value: "No upcoming execution")
                }

                if let lastExecution = schedule.lastExecution {
                    DetailRow(title: "Last Execution", value: lastExecution, formatter: .relative)
                } else {
                    DetailRow(title: "Last Execution", value: "Never executed")
                }
            }
        }
    }

    // MARK: - Routine Context Section

    private func routineContextSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Routine Context")

            VStack(spacing: 8) {
                DetailRow(title: "Routine ID", value: String(schedule.routineId.prefix(8)) + "...")
                // TODO: Add routine name lookup and navigation link
                HStack {
                    Text("Routine")
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("View Routine") {
                        // TODO: Navigate to routine detail
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
                }
            }
        }
    }

    // MARK: - Execution History Section

    private func executionHistorySection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("History")

            VStack(spacing: 8) {
                DetailRow(title: "Created", value: schedule.createdAt, formatter: .dateTime)

                if schedule.updatedAt != schedule.createdAt {
                    DetailRow(title: "Last Modified", value: schedule.updatedAt, formatter: .dateTime)
                }

                // TODO: Add execution history when available
                DetailRow(title: "Total Executions", value: "N/A")
            }
        }
    }

    // MARK: - Quick Actions Section

    private func quickActionsSection(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Quick Actions")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                actionButton(
                    title: schedule.enabled ? "Pause" : "Resume",
                    systemImage: schedule.enabled ? "pause.circle" : "play.circle",
                    color: schedule.enabled ? .orange : .green
                ) {
                    Task {
                        await viewModel.toggleScheduleEnabled(schedule)
                    }
                }

                actionButton(
                    title: "Test Run",
                    systemImage: "play.fill",
                    color: .blue,
                    isLoading: isTestingSchedule
                ) {
                    isTestingSchedule = true
                    Task {
                        await viewModel.testSchedule(schedule)
                        isTestingSchedule = false
                    }
                }
            }
        }
    }

    // MARK: - Helper Views

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fontWeight(.semibold)
    }

    private func statusCard(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func actionButton(
        title: String,
        systemImage: String,
        color: Color,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.medium)
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(isLoading)
    }

    private func scheduleToolbarButtons(_ schedule: Schedule) -> some View {
        HStack {
            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Edit schedule")

            Button {
                showDuplicateSheet = true
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Duplicate schedule")

            Button {
                showDeleteAlert = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete schedule")
        }
    }

    // MARK: - Helper Methods

    private func syncStatusText(_ schedule: Schedule) -> String {
        let status = viewModel.getSyncStatus(for: schedule.id) ?? .localOnly
        switch status {
        case .localOnly:
            return "Local Only"
        case .pendingSync:
            return "Pending Sync"
        case .synced:
            return "Synced"
        case .syncFailed:
            return "Sync Failed"
        case .pendingDelete:
            return "Pending Delete"
        case .conflict:
            return "Conflict"
        }
    }

    private func syncStatusColor(_ schedule: Schedule) -> Color {
        let status = viewModel.getSyncStatus(for: schedule.id) ?? .localOnly
        switch status {
        case .localOnly:
            return .blue
        case .pendingSync:
            return .orange
        case .synced:
            return .green
        case .syncFailed:
            return .red
        case .pendingDelete:
            return .red
        case .conflict:
            return .purple
        }
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    init(title: String, value: Date, formatter: DetailRowFormatter = .dateTime) {
        self.title = title
        self.value = Self.formatDate(value, with: formatter)
    }

    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
        }
    }

    static func formatDate(_ date: Date, with formatter: DetailRowFormatter) -> String {
        switch formatter {
        case .none:
            return ""
        case .dateTime:
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        case .relative:
            return date.formatted(.relative(presentation: .named))
        }
    }
}

enum DetailRowFormatter {
    case none
    case dateTime
    case relative
}

#Preview {
    Group {
        ScheduleDetailView(
            schedule: Schedule(
                routineId: "preview",
                name: "Eye Care Schedule",
                recurrenceJSON: "{\"freq\":\"MINUTELY\",\"interval\":20}",
                notes: "20-20-20 rule for eye health"
            ),
            viewModel: ScheduleViewModel()
        )

        ScheduleDetailView(
            schedule: nil,
            viewModel: ScheduleViewModel()
        )

        ScheduleDetailView(
            schedule: nil,
            viewModel: ScheduleViewModel(),
            isCreating: true
        )
    }
}