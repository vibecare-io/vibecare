import SwiftUI
import SwiftData
import Logging

#if DEBUG
struct DebugStorageView: View {
    @ObservedObject private var localStorage = RoutineLocalStorage.shared
    @State private var routines: [RoutineEntity] = []
    @State private var syncStatistics: [SyncStatus: Int] = [:]
    @State private var selectedRoutine: RoutineEntity?
    @State private var isLoading = false

    private let logger = Logger(label: "com.vibecare.debug-storage")

    var body: some View {
        NavigationSplitView {
            // Sidebar with storage overview
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                statisticsSection
                routinesListSection

                Divider()

                // All Data Section
                allDataSection
            }
            .padding()
            .frame(minWidth: 300)
            .navigationTitle("Storage Debug")

        } detail: {
            // Detail view for selected routine
            if let selectedRoutine = selectedRoutine {
                RoutineDetailDebugView(routine: selectedRoutine)
            } else {
                StorageOverviewDetailView(
                    routines: routines,
                    syncStatistics: syncStatistics
                )
            }
        }
        .onAppear {
            refreshData()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", action: refreshData)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear All") {
                    clearAllData()
                }
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("SwiftData Storage", systemImage: "database.fill")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Local storage contents")
                .font(.caption)
                .foregroundColor(.secondary)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Statistics")
                .font(.subheadline)
                .fontWeight(.medium)

            if syncStatistics.isEmpty {
                Text("No data")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SyncStatus.allCases, id: \.self) { status in
                        let count = syncStatistics[status] ?? 0
                        if count > 0 {
                            HStack {
                                Circle()
                                    .fill(colorFor(status: status))
                                    .frame(width: 8, height: 8)
                                Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Routines List Section

    private var routinesListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routines (\(routines.count))")
                .font(.subheadline)
                .fontWeight(.medium)

            if routines.isEmpty {
                ContentUnavailableView("No Routines",
                                     systemImage: "list.bullet",
                                     description: Text("No routines found in local storage"))
                .frame(maxHeight: 200)
            } else {
                List(routines, id: \.id, selection: $selectedRoutine) { routine in
                    RoutineRowDebugView(routine: routine)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - All Data Section

    private var allDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw Data Preview")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(spacing: 4) {
                Button("Show All Data") {
                    selectedRoutine = nil // This will show the overview
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Clear All Data") {
                    clearAllData()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .controlSize(.small)
            }

            if !routines.isEmpty {
                Text("Sample: \(routines.first?.name ?? "N/A")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .background(Color.pink.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Routine Row Debug View

struct RoutineRowDebugView: View {
    let routine: RoutineEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(routine.enabled ? .green : .orange)
                    .frame(width: 6, height: 6)

                Text(routine.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                Circle()
                    .fill(colorFor(status: routine.syncStatus))
                    .frame(width: 8, height: 8)
            }

            Text("ID: \(routine.id.prefix(8))...")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack {
                Text(routine.syncStatus.rawValue.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(colorFor(status: routine.syncStatus).opacity(0.2))
                    .foregroundColor(colorFor(status: routine.syncStatus))
                    .cornerRadius(4)

                Spacer()

                Text("\(routine.actionIds.count) actions")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Routine Detail Debug View

struct RoutineDetailDebugView: View {
    let routine: RoutineEntity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Basic Info
                basicInfoSection

                // Metadata
                metadataSection

                // Sync Info
                syncInfoSection

                // Actions
                actionsSection

                // Raw Data
                rawDataSection
            }
            .padding()
        }
        .navigationTitle(routine.name)
    }

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Basic Information", systemImage: "info.circle")
                .font(.headline)

            InfoRow(label: "ID", value: routine.id)
            InfoRow(label: "Profile ID", value: routine.profileId)
            InfoRow(label: "Name", value: routine.name)
            InfoRow(label: "Description", value: routine.routineDescription.isEmpty ? "None" : routine.routineDescription)
            InfoRow(label: "Enabled", value: routine.enabled ? "Yes" : "No")
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Metadata", systemImage: "tag")
                .font(.headline)

            if routine.metadata.isEmpty {
                Text("No metadata")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(routine.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        InfoRow(label: key.capitalized, value: value)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var syncInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sync Information", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            InfoRow(label: "Status", value: routine.syncStatus.rawValue.capitalized)
            InfoRow(label: "Created", value: routine.createdAt.formatted())
            InfoRow(label: "Updated", value: routine.updatedAt.formatted())
            InfoRow(label: "Last Modified", value: routine.lastModified.formatted())

            if let lastSyncAttempt = routine.lastSyncAttempt {
                InfoRow(label: "Last Sync Attempt", value: lastSyncAttempt.formatted())
            }

            if let lastExecuted = routine.lastExecutedAt {
                InfoRow(label: "Last Executed", value: lastExecuted.formatted())
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Actions (\(routine.actionIds.count))", systemImage: "bolt")
                .font(.headline)

            if routine.actionIds.isEmpty {
                Text("No actions")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(routine.actionIds.enumerated()), id: \.offset) { index, actionId in
                        InfoRow(label: "Action \(index + 1)", value: actionId)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var rawDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Raw Data", systemImage: "doc.text")
                .font(.headline)

            Text("Entity properties as stored in SwiftData")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Action IDs: \(routine.actionIds)")
                    .font(.caption.monospaced())

                Text("Metadata: \(routine.metadata)")
                    .font(.caption.monospaced())
            }
            .padding(8)
            .background(Color.black.opacity(0.05))
            .cornerRadius(4)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text("\(label):")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 80, alignment: .leading)

            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            Spacer()
        }
    }
}

// MARK: - Helper Functions

private func colorFor(status: SyncStatus) -> Color {
    switch status {
    case .localOnly:
        return .blue
    case .synced:
        return .green
    case .pendingSync:
        return .orange
    case .conflict:
        return .purple
    case .syncFailed:
        return .red
    case .pendingDelete:
        return .gray
    }
}

// MARK: - Debug Storage View Extension

extension DebugStorageView {
    private func refreshData() {
        isLoading = true

        Task { @MainActor in
            do {
                // Get current profile
                let profileId = AppState.shared.currentProfile?.id ?? "unknown"

                // Convert to entities for inspection
                // We need to access the underlying SwiftData entities
                routines = try await fetchRoutineEntities(for: profileId)

                // Get sync statistics
                syncStatistics = try localStorage.getSyncStatistics()

                logger.info("Refreshed debug storage view: \(routines.count) routines")

            } catch {
                logger.error("Failed to refresh debug storage data: \(error)")
            }

            isLoading = false
        }
    }

    private func fetchRoutineEntities(for profileId: String) async throws -> [RoutineEntity] {
        return try localStorage.getAllRoutineEntities(for: profileId)
    }

    private func clearAllData() {
        Task { @MainActor in
            do {
                let profileId = AppState.shared.currentProfile?.id ?? "unknown"
                try localStorage.clearAllRoutines(for: profileId)
                refreshData()
                logger.info("Cleared all debug storage data")
            } catch {
                logger.error("Failed to clear debug storage data: \(error)")
            }
        }
    }
}

// MARK: - Storage Overview Detail View

struct StorageOverviewDetailView: View {
    let routines: [RoutineEntity]
    let syncStatistics: [SyncStatus: Int]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Statistics Overview
                statisticsOverviewSection

                // All Routines Data
                allRoutinesSection
            }
            .padding()
        }
        .navigationTitle("Storage Overview")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundColor(.pink)

                VStack(alignment: .leading) {
                    Text("SwiftData Storage Contents")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Complete cached data inspection")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()
        }
    }

    private var statisticsOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Storage Statistics", systemImage: "chart.bar")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach(SyncStatus.allCases, id: \.self) { status in
                    let count = syncStatistics[status] ?? 0
                    StatCard(
                        title: status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        count: count,
                        color: colorFor(status: status)
                    )
                }
            }

            HStack {
                Text("Total Records:")
                    .fontWeight(.medium)
                Spacer()
                Text("\(routines.count)")
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private var allRoutinesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("All Cached Routines (\(routines.count))", systemImage: "list.bullet.rectangle")
                .font(.headline)

            if routines.isEmpty {
                EmptyStorageView()
            } else {
                ForEach(routines, id: \.id) { routine in
                    RoutineDataCard(routine: routine)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct RoutineDataCard: View {
    let routine: RoutineEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with name and sync status
            HStack {
                Circle()
                    .fill(routine.enabled ? .green : .orange)
                    .frame(width: 8, height: 8)

                Text(routine.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Spacer()

                Text(routine.syncStatus.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(colorFor(status: routine.syncStatus).opacity(0.2))
                    .foregroundColor(colorFor(status: routine.syncStatus))
                    .cornerRadius(4)
            }

            // Key details
            VStack(alignment: .leading, spacing: 4) {
                DebugDetailRow(label: "ID", value: routine.id)
                DebugDetailRow(label: "Profile ID", value: routine.profileId)

                if !routine.routineDescription.isEmpty {
                    DebugDetailRow(label: "Description", value: routine.routineDescription)
                }

                DebugDetailRow(label: "Actions", value: "\(routine.actionIds.count) actions")
                DebugDetailRow(label: "Enabled", value: routine.enabled ? "Yes" : "No")
                DebugDetailRow(label: "Created", value: routine.createdAt.formatted(date: .abbreviated, time: .shortened))
                DebugDetailRow(label: "Updated", value: routine.updatedAt.formatted(date: .abbreviated, time: .shortened))

                if let lastExecution = routine.lastExecutedAt {
                    DebugDetailRow(label: "Last Executed", value: lastExecution.formatted(date: .abbreviated, time: .shortened))
                }

                if let lastSync = routine.lastSyncAttempt {
                    DebugDetailRow(label: "Last Sync Attempt", value: lastSync.formatted(date: .abbreviated, time: .shortened))
                }
            }

            // Metadata
            if !routine.metadata.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Metadata:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(routine.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack {
                            Text("• \(key):")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(value)
                                .font(.caption2)
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            }

            // Action IDs
            if !routine.actionIds.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Action IDs:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    Text(routine.actionIds.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(colorFor(status: routine.syncStatus).opacity(0.3), lineWidth: 1)
        )
    }
}

struct DebugDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text("\(label):")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

struct EmptyStorageView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            Text("No Data in Storage")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Local SwiftData storage is empty. Create some routines to see them here.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

#endif