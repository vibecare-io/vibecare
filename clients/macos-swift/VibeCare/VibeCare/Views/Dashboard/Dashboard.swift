import SwiftUI

public struct Dashboard: View {

  @EnvironmentObject private var appState: AppState
  @StateObject private var dashboardState = DashboardState()
  @StateObject private var routineViewModel = RoutineViewModel()
  @StateObject private var scheduleViewModel = ScheduleViewModel()
  @StateObject private var actionViewModel = ActionViewModel()
  @StateObject private var notificationPolicy = NotificationPolicy.shared

  public init() {}

  // Keyboard navigation
  @FocusState private var isListFocused: Bool

  public var body: some View {
    ZStack {
      mainNavigationView
        .onAppear {
          loadData()
        }
        .onChange(of: appState.currentProfile) { _, _ in
          loadData()
        }

      // Global status bar
      VStack {
        Spacer()
        StatusBarView()
      }
    }
  }

  private var mainNavigationView: some View {
    NavigationSplitView(columnVisibility: $dashboardState.columnVisibility) {
      sidebarView
    } content: {
      contentView
    } detail: {
      detailView
    }
    .navigationSplitViewStyle(.balanced)
    .searchable(text: $dashboardState.searchText, placement: .sidebar)
    .modifier(
      KeyboardShortcutsModifier(
        searchText: $dashboardState.searchText,
        showHelp: $dashboardState.showHelp,
        handleKeyPress: handleKeyPress
      )
    )
    .sheet(isPresented: $dashboardState.showHelp) {
      HelpView()
    }
    .sheet(isPresented: $dashboardState.showAddSheet) {
      addItemSheet
    }
  }

  // MARK: - Sidebar View

  private var sidebarView: some View {
    DashboardSidebar(
      selectedItem: $dashboardState.selectedSidebarItem,
      showAddSheet: $dashboardState.showAddSheet,
      routineCount: routineViewModel.routines.count,
      scheduleCount: scheduleViewModel.schedules.count,
      actionCount: actionViewModel.actions.count
    )
  }

  // MARK: - Content View

  @ViewBuilder
  private var contentView: some View {
    contentViewForSelectedItem
      .navigationTitle(dashboardState.selectedSidebarItem?.rawValue ?? "Dashboard")
      .toolbar {
        ToolbarItemGroup(placement: .primaryAction) {
          toolbarButtons
        }
      }
  }

  @ViewBuilder
  private var contentViewForSelectedItem: some View {
    switch dashboardState.selectedSidebarItem {
    case .routines:
      routineContentView
    case .schedules:
      scheduleContentView
    case .actions:
      actionContentView
    case .logs:
      logContentView
    case .testing:
      testingContentView
    case .settings:
      settingsContentView
    #if DEBUG
      case .debugStorage:
        debugStorageContentView
    #endif
    case .none:
      emptyContentView
    }
  }

  private var routineContentView: some View {
    RoutineListView(
      viewModel: routineViewModel,
      searchText: dashboardState.searchText,
      selectedId: $dashboardState.selectedRoutineId
    )
    .focused($isListFocused)
  }

  private var scheduleContentView: some View {
    ScheduleListView(
      viewModel: scheduleViewModel,
      searchText: dashboardState.searchText,
      selectedId: $dashboardState.selectedScheduleId
    )
  }

  private var actionContentView: some View {
    ActionLibraryView(
      viewModel: actionViewModel,
      searchText: dashboardState.searchText,
      selectedId: $dashboardState.selectedActionId
    )
  }

  private var logContentView: some View {
    ExecutionLogView(
      searchText: dashboardState.searchText,
      selectedId: $dashboardState.selectedLogId
    )
  }

  @ViewBuilder
  private var testingContentView: some View {
    if #available(macOS 15.0, *) {
      GRPCTestView(selectedResult: $dashboardState.selectedTestResult)
    } else {
      Text("gRPC Testing requires macOS 15.0 or later")
        .foregroundColor(.secondary)
    }
  }

  private var settingsContentView: some View {
    SettingsContentView(selectedCategory: $dashboardState.selectedSettingCategory)
  }

  #if DEBUG
    private var debugStorageContentView: some View {
      // TODO: Implement DebugStorageView
      EmptyStateView(
        title: "Debug Storage",
        subtitle: "Storage debugging view coming soon",
        systemImage: "internaldrive"
      )
    }
  #endif

  private var emptyContentView: some View {
    EmptyStateView(
      title: "Welcome to VibeCare",
      subtitle: "Select an item from the sidebar to get started",
      systemImage: "heart.circle"
    )
  }

  @ViewBuilder
  private var toolbarButtons: some View {
    // Notification toggle (always visible)
    Button {
      notificationPolicy.toggle()
    } label: {
      Image(systemName: notificationPolicy.enabled ? "bell.fill" : "bell.slash.fill")
    }
    .help(notificationPolicy.enabled ? "Disable notifications" : "Enable notifications")

    // Section-specific buttons
    switch dashboardState.selectedSidebarItem {
    case .routines:
      routineToolbarButtons
    case .schedules:
      scheduleToolbarButtons
    case .actions:
      actionToolbarButtons
    default:
      EmptyView()
    }
  }

  // MARK: - Detail View

  @ViewBuilder
  private var detailView: some View {
    switch dashboardState.selectedSidebarItem {
    case .routines:
      routineDetailView
    case .schedules:
      scheduleDetailView
    case .actions:
      actionDetailView
    case .logs:
      logDetailView
    case .testing:
      testingDetailView
    case .settings:
      settingsDetailView
    #if DEBUG
      case .debugStorage:
        emptyDetailView  // Debug storage view doesn't need a separate detail view
    #endif
    case .none:
      emptyDetailView
    }
  }

  private var emptyDetailView: some View {
    EmptyStateView(
      title: "Welcome to VibeCare",
      subtitle: "Select an item from the sidebar to get started",
      systemImage: "heart.circle"
    )
  }

  @ViewBuilder
  private var routineDetailView: some View {
    if let routineId = dashboardState.selectedRoutineId {
      if routineId == "new-routine" {
        // Show creation form
        RoutineDetailView(
          routine: nil,
          viewModel: routineViewModel,
          isCreating: true,
          onCancel: {
            dashboardState.selectedRoutineId = nil
          }
        )
      } else if let routine = routineViewModel.routines.first(where: { $0.id == routineId }) {
        // Show existing routine
        RoutineDetailView(routine: routine, viewModel: routineViewModel, isCreating: false)
      } else {
        // Selected routine not found
        EmptyStateView(
          title: "Routine Not Found",
          subtitle: "The selected routine could not be found",
          systemImage: "exclamationmark.triangle"
        )
      }
    } else {
      // No selection
      EmptyStateView(
        title: "No Routine Selected",
        subtitle: "Select a routine to view details or create a new one",
        systemImage: "list.bullet.circle"
      )
    }
  }

  @ViewBuilder
  private var scheduleDetailView: some View {
    if let scheduleId = dashboardState.selectedScheduleId,
      let schedule = scheduleViewModel.schedules.first(where: { $0.id == scheduleId })
    {
      ScheduleDetailView(schedule: schedule, viewModel: scheduleViewModel)
    } else {
      EmptyStateView(
        title: "No Schedule Selected",
        subtitle: "Select a schedule to view details",
        systemImage: "calendar.circle"
      )
    }
  }

  @ViewBuilder
  private var actionDetailView: some View {
    if let actionId = dashboardState.selectedActionId,
      let action = actionViewModel.actions.first(where: { $0.id == actionId })
    {
      ActionDetailView(action: action, viewModel: actionViewModel)
    } else {
      EmptyStateView(
        title: "No Action Selected",
        subtitle: "Select an action to view details",
        systemImage: "bolt.circle"
      )
    }
  }

  @ViewBuilder
  private var logDetailView: some View {
    if let logId = dashboardState.selectedLogId {
      EmptyStateView(
        title: "Log Details",
        subtitle: "Log ID: \(logId)",
        systemImage: "doc.circle"
      )
    } else {
      EmptyStateView(
        title: "No Log Selected",
        subtitle: "Select an execution log to view details",
        systemImage: "doc.circle"
      )
    }
  }

  @ViewBuilder
  private var testingDetailView: some View {
    if let testResult = dashboardState.selectedTestResult {
      TestingDetailView(testResult: testResult)
    } else {
      EmptyStateView(
        title: "No Test Selected",
        subtitle: "Run a test to see detailed results here",
        systemImage: "network.circle"
      )
    }
  }

  @ViewBuilder
  private var settingsDetailView: some View {
    if let category = dashboardState.selectedSettingCategory {
      SettingsDetailView(selectedSetting: category)
    } else {
      EmptyStateView(
        title: "No Setting Selected",
        subtitle: "Select a setting category to configure options",
        systemImage: "gearshape.circle"
      )
    }
  }

  // MARK: - Toolbar Buttons

  private var routineToolbarButtons: some View {
    Button {
      Task {
        await routineViewModel.refreshData()
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .help("Refresh routines")
  }

  private var scheduleToolbarButtons: some View {
    Button {
      Task {
        await scheduleViewModel.refreshData()
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .help("Refresh schedules")
  }

  private var actionToolbarButtons: some View {
    Button {
      Task {
        await actionViewModel.refreshData()
      }
    } label: {
      Image(systemName: "arrow.clockwise")
    }
    .help("Refresh actions")
  }

  // MARK: - Add Item Sheet

  private var addItemSheet: some View {
    Group {
      switch dashboardState.selectedSidebarItem {
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

  private func handleKeyPress(_ direction: KeyDirection) -> KeyPress.Result {
    guard isListFocused else { return .ignored }

    switch dashboardState.selectedSidebarItem {
    case .routines:
      return handleRoutineNavigation(direction)
    default:
      return .ignored
    }
  }

  private func handleRoutineNavigation(_ direction: KeyDirection) -> KeyPress.Result {
    let routines = routineViewModel.filteredRoutines(searchText: dashboardState.searchText)
    guard !routines.isEmpty else { return .ignored }

    let currentIndex = routines.firstIndex { $0.id == dashboardState.selectedRoutineId } ?? -1

    let newIndex: Int
    switch direction {
    case .up:
      newIndex = max(0, currentIndex - 1)
    case .down:
      newIndex = min(routines.count - 1, currentIndex + 1)
    }

    dashboardState.selectRoutine(routines[newIndex].id)
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

struct KeyboardShortcutsModifier: ViewModifier {
  @Binding var searchText: String
  @Binding var showHelp: Bool
  let handleKeyPress: (KeyDirection) -> KeyPress.Result

  func body(content: Content) -> some View {
    content
      .onKeyPress(.upArrow) {
        handleKeyPress(.up)
      }
      .onKeyPress(.downArrow) {
        handleKeyPress(.down)
      }
      .onKeyPress("j") {
        handleKeyPress(.down)
      }
      .onKeyPress("k") {
        handleKeyPress(.up)
      }
      .onKeyPress("/") {
        searchText = ""
        return .handled
      }
      .onKeyPress("?") {
        showHelp.toggle()
        return .handled
      }
  }
}

// MARK: - Preview

#Preview {
  Dashboard()
    .environmentObject(AppState.shared)
    .frame(width: 1200, height: 800)
}
