import SwiftUI
import Combine
import Logging

@MainActor
class ActionViewModel: ObservableObject {
    @Published var actions: [Action] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let logger = Logger(label: "com.vibecare.action-viewmodel")

    init() {
    }

    func loadActions(for profileId: String) async {
        isLoading = true
        errorMessage = nil

        do {
            // TODO: Load actions from backend API
            // For now, start with empty actions list
            actions = []
            logger.info("Loaded \(actions.count) actions")
        } catch {
            logger.error("Failed to load actions: \(error)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refreshData() async {
        guard let currentProfile = AppState.shared.currentProfile else { return }
        await loadActions(for: currentProfile.id)
    }

}
