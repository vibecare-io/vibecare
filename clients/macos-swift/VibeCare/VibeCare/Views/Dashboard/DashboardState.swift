import SwiftUI

final class DashboardState: ObservableObject {
    // MARK: - Selection State
    @Published var selectedSidebarItem: SidebarItem? = .schedules
    @Published var selectedRoutineId: String?
    @Published var selectedScheduleId: String?
    @Published var selectedActionId: String?
    @Published var selectedSettingCategory: SettingCategory?

    // MARK: - UI State
    @Published var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @Published var searchText = ""
    @Published var showHelp = false
    @Published var showAddSheet = false
    @Published var selectedIndex: Int = 0

    // MARK: - Computed Properties
    var hasSelectedItem: Bool {
        switch selectedSidebarItem {
        case .routines:
            return selectedRoutineId != nil
        case .schedules:
            return selectedScheduleId != nil
        case .actions:
            return selectedActionId != nil
        case .settings:
            return selectedSettingCategory != nil
        case .none:
            return false
        }
    }

    // MARK: - Methods
    func clearAllSelections() {
        selectedRoutineId = nil
        selectedScheduleId = nil
        selectedActionId = nil
        selectedSettingCategory = nil
    }

    func updateColumnVisibility() {
        columnVisibility = hasSelectedItem ? .all : .doubleColumn
    }

    func selectSidebarItem(_ item: SidebarItem?) {
        selectedSidebarItem = item
        clearAllSelections()
        updateColumnVisibility()
    }

    func selectRoutine(_ id: String?) {
        selectedRoutineId = id
        updateColumnVisibility()
    }

    func selectSchedule(_ id: String?) {
        selectedScheduleId = id
        updateColumnVisibility()
    }

    func selectAction(_ id: String?) {
        selectedActionId = id
        updateColumnVisibility()
    }

    func selectSettingCategory(_ category: SettingCategory?) {
        selectedSettingCategory = category
        updateColumnVisibility()
    }
}