import SwiftUI
import Combine
import Logging

@MainActor
class ScheduleViewModel: ObservableObject {
    @Published var schedules: [Schedule] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(label: "com.vibecare.schedule-viewmodel")

    init() {
    }

    func loadSchedules(for profileId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            // TODO: Load schedules from backend API
            // For now, start with empty schedules list
            schedules = []
            logger.info("Loaded \(schedules.count) schedules")
        } catch {
            logger.error("Failed to load schedules: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadSchedules(for: currentProfile.id)
    }

}
