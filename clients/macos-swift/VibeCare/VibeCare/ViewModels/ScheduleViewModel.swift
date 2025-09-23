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
        loadSampleData()
    }

    func loadSchedules(for profileId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            // Simulate API call
            try await Task.sleep(nanoseconds: 500_000_000)

            // Load sample schedules
            let sampleRoutines = Routine.samples(for: profileId, with: [])
            schedules = Schedule.samples(for: sampleRoutines)

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

    private func loadSampleData() {
        let sampleRoutines = Routine.samples(for: "sample", with: [])
        schedules = Schedule.samples(for: sampleRoutines)
    }
}
