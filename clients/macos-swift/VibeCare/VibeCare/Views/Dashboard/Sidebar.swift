import SwiftUI

// MARK: - Sidebar Item Definition
enum SidebarItem: String, CaseIterable, Identifiable {
    case routines = "Routines"
    case schedules = "Schedules"
    case actions = "Actions"
    case logs = "Execution Logs"
    case testing = "gRPC Testing"
    case settings = "Settings"
    #if DEBUG
    case debugStorage = "🔧 Storage Debug"
    #endif

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .routines: return "list.bullet"
        case .schedules: return "calendar.badge.clock"
        case .actions: return "bolt.circle"
        case .logs: return "doc.text"
        case .testing: return "network"
        case .settings: return "gearshape.fill"
        #if DEBUG
        case .debugStorage: return "internaldrive"
        #endif
        }
    }

    var color: Color {
        switch self {
        case .routines: return .blue
        case .schedules: return .orange
        case .actions: return .purple
        case .logs: return .green
        case .testing: return .red
        case .settings: return .gray
        #if DEBUG
        case .debugStorage: return .pink
        #endif
        }
    }
}

// MARK: - Sidebar View
struct DashboardSidebar: View {
    @Binding var selectedItem: SidebarItem?
    @Binding var showAddSheet: Bool

    let routineCount: Int
    let scheduleCount: Int
    let actionCount: Int

    var body: some View {
        List(selection: $selectedItem) {
            ForEach(SidebarItem.allCases) { item in
                NavigationLink(value: item) {
                    SidebarItemRow(
                        item: item,
                        count: getItemCount(for: item)
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("VibeCare")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private func getItemCount(for item: SidebarItem) -> Int? {
        switch item {
        case .routines:
            return routineCount
        case .schedules:
            return scheduleCount
        case .actions:
            return actionCount
        case .logs:
            return nil // Don't show count for logs
        case .testing:
            return nil // Don't show count for testing
        case .settings:
            return nil
        #if DEBUG
        case .debugStorage:
            return nil // Don't show count for debug storage
        #endif
        }
    }
}

// MARK: - Sidebar Item Row
struct SidebarItemRow: View {
    let item: SidebarItem
    let count: Int?

    var body: some View {
        HStack {
            Image(systemName: item.iconName)
                .foregroundColor(item.color)
                .frame(width: 20)

            Text(item.rawValue)

            Spacer()

            // Show count badges
            if let count = count, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationSplitView {
        DashboardSidebar(
            selectedItem: .constant(.routines),
            showAddSheet: .constant(false),
            routineCount: 5,
            scheduleCount: 3,
            actionCount: 8
        )
    } content: {
        Text("Content")
    } detail: {
        Text("Detail")
    }
}