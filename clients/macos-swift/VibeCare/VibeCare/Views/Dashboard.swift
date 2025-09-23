import SwiftUI

struct Dashboard: View {
    enum SidebarItem: String, CaseIterable, Identifiable {
        case routines = "Routines"
        case schedules = "Schedules"
        case actions = "Actions"
        case logs = "Execution Logs"
        case settings = "Settings"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .routines: return "list.bullet"
            case .schedules: return "calendar.badge.clock"
            case .actions: return "bolt.circle"
            case .logs: return "doc.text"
            case .settings: return "gearshape.fill"
            }
        }

        var color: Color {
            switch self {
            case .routines: return .blue
            case .schedules: return .orange
            case .actions: return .purple
            case .logs: return .green
            case .settings: return .gray
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @StateObject private var routineViewModel = RoutineViewModel()
    @StateObject private var scheduleViewModel = ScheduleViewModel()
    @StateObject private var actionViewModel = ActionViewModel()

    @State private var selectedSidebarItem: SidebarItem? = .routines
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedRoutineId: String?
    @State private var showInspector = false
    @State private var searchText = ""
    @State private var showHelp = false
    @State private var showAddSheet = false

    // Keyboard navigation
    @FocusState private var isListFocused: Bool
    @State private var selectedIndex: Int = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } content: {
            contentView
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $showInspector) {
            inspectorView
        }
        .searchable(text: $searchText, placement: .sidebar)
        .onKeyPress(.upArrow) { handleKeyPress(.up) }
        .onKeyPress(.downArrow) { handleKeyPress(.down) }
        .onKeyPress("j") { handleKeyPress(.down) }
        .onKeyPress("k") { handleKeyPress(.up) }
        .onKeyPress("/") {
            searchText = ""
            return .handled
        }
        .onKeyPress("?") {
            showHelp.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            showInspector = false
            return .handled
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .sheet(isPresented: $showAddSheet) {
            addItemSheet
        }
        .onAppear {
            loadData()
        }
        .onChange(of: appState.currentProfile) { _, _ in
            loadData()
        }
    }

    // MARK: - Sidebar View

    private var sidebarView: some View {
        List(selection: $selectedSidebarItem) {
            ForEach(SidebarItem.allCases) { item in
                NavigationLink(value: item) {
                    HStack {
                        Image(systemName: item.iconName)
                            .foregroundColor(item.color)
                            .frame(width: 20)

                        Text(item.rawValue)

                        Spacer()

                        // Show count badges
                        if let count = getItemCount(for: item), count > 0 {
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

    // MARK: - Content View

    private var contentView: some View {
        Group {
            switch selectedSidebarItem {
            case .routines:
                RoutineListView(
                    viewModel: routineViewModel,
                    searchText: searchText,
                    selectedId: $selectedRoutineId,
                    showInspector: $showInspector
                )
                .focused($isListFocused)

            case .schedules:
                ScheduleListView(
                    viewModel: scheduleViewModel,
                    searchText: searchText,
                    showInspector: $showInspector
                )

            case .actions:
                ActionLibraryView(
                    viewModel: actionViewModel,
                    searchText: searchText,
                    showInspector: $showInspector
                )

            case .logs:
                ExecutionLogView(searchText: searchText)

            case .settings:
                SettingsContentView()

            case .none:
                EmptyStateView(
                    title: "Welcome to VibeCare",
                    subtitle: "Select an item from the sidebar to get started",
                    systemImage: "heart.circle"
                )
            }
        }
        .navigationTitle(selectedSidebarItem?.rawValue ?? "Dashboard")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedSidebarItem == .routines {
                    routineToolbarButtons
                } else if selectedSidebarItem == .schedules {
                    scheduleToolbarButtons
                } else if selectedSidebarItem == .actions {
                    actionToolbarButtons
                }
            }
        }
    }

    // MARK: - Detail View

    private var detailView: some View {
        Group {
            if let routineId = selectedRoutineId,
               let routine = routineViewModel.routines.first(where: { $0.id == routineId }) {
                RoutineDetailView(routine: routine, viewModel: routineViewModel)
            } else {
                EmptyStateView(
                    title: "No Selection",
                    subtitle: getDetailMessage(),
                    systemImage: getDetailIcon()
                )
            }
        }
    }

    // MARK: - Inspector View

    private var inspectorView: some View {
        Group {
            switch selectedSidebarItem {
            case .routines:
                if let routineId = selectedRoutineId {
                    RoutineInspectorView(
                        routineId: routineId,
                        viewModel: routineViewModel
                    )
                } else {
                    Text("Select a routine to edit")
                        .foregroundColor(.secondary)
                }

            case .schedules:
                ScheduleInspectorView(viewModel: scheduleViewModel)

            case .actions:
                ActionInspectorView(viewModel: actionViewModel)

            default:
                Text("No inspector available")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 300, idealWidth: 350)
        .navigationTitle("Inspector")
    }

    // MARK: - Toolbar Buttons

    private var routineToolbarButtons: some View {
        HStack {
            Button {
                Task {
                    await routineViewModel.refreshData()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh routines")

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundColor(showInspector ? .accentColor : .primary)
            }
            .help("Toggle inspector")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private var scheduleToolbarButtons: some View {
        HStack {
            Button {
                Task {
                    await scheduleViewModel.refreshData()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh schedules")

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundColor(showInspector ? .accentColor : .primary)
            }
            .help("Toggle inspector")
        }
    }

    private var actionToolbarButtons: some View {
        HStack {
            Button {
                Task {
                    await actionViewModel.refreshData()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh actions")

            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundColor(showInspector ? .accentColor : .primary)
            }
            .help("Toggle inspector")
        }
    }

    // MARK: - Add Item Sheet

    private var addItemSheet: some View {
        Group {
            switch selectedSidebarItem {
            case .routines:
                RoutineFormView(viewModel: routineViewModel)
            case .schedules:
                ScheduleFormView(viewModel: scheduleViewModel)
            case .actions:
                ActionFormView(viewModel: actionViewModel)
            default:
                Text("Cannot add items for this section")
            }
        }
    }

    // MARK: - Helper Methods

    private func getItemCount(for item: SidebarItem) -> Int? {
        switch item {
        case .routines:
            return routineViewModel.routines.count
        case .schedules:
            return scheduleViewModel.schedules.count
        case .actions:
            return actionViewModel.actions.count
        case .logs:
            return nil // Don't show count for logs
        case .settings:
            return nil
        }
    }

    private func getDetailMessage() -> String {
        switch selectedSidebarItem {
        case .routines:
            return "Select a routine to view details or create a new one"
        case .schedules:
            return "Select a schedule to view details"
        case .actions:
            return "Select an action to view details"
        case .logs:
            return "View execution logs here"
        case .settings:
            return "Configure your VibeCare settings"
        case .none:
            return "Select an item from the sidebar"
        }
    }

    private func getDetailIcon() -> String {
        switch selectedSidebarItem {
        case .routines: return "list.bullet.circle"
        case .schedules: return "calendar.circle"
        case .actions: return "bolt.circle"
        case .logs: return "doc.circle"
        case .settings: return "gearshape.circle"
        case .none: return "heart.circle"
        }
    }

    private func handleKeyPress(_ direction: KeyDirection) -> KeyPress.Result {
        guard isListFocused else { return .ignored }

        switch selectedSidebarItem {
        case .routines:
            return handleRoutineNavigation(direction)
        default:
            return .ignored
        }
    }

    private func handleRoutineNavigation(_ direction: KeyDirection) -> KeyPress.Result {
        let routines = routineViewModel.filteredRoutines(searchText: searchText)
        guard !routines.isEmpty else { return .ignored }

        let currentIndex = routines.firstIndex { $0.id == selectedRoutineId } ?? -1

        let newIndex: Int
        switch direction {
        case .up:
            newIndex = max(0, currentIndex - 1)
        case .down:
            newIndex = min(routines.count - 1, currentIndex + 1)
        }

        selectedRoutineId = routines[newIndex].id
        return .handled
    }

    private func loadData() {
        guard let profile = appState.currentProfile else { return }

        Task {
            await routineViewModel.loadRoutines(for: profile.id)
            await scheduleViewModel.loadSchedules(for: profile.id)
            await actionViewModel.loadActions(for: profile.id)
        }
    }
}

// MARK: - Supporting Types

enum KeyDirection {
    case up, down
}

// MARK: - Preview

#Preview {
    Dashboard()
        .environmentObject(AppState.shared)
        .frame(width: 1200, height: 800)
}