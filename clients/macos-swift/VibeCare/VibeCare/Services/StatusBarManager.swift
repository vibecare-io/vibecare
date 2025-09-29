import SwiftUI
import Combine

enum StatusMessageType {
    case info
    case success
    case warning
    case error
    case loading

    var color: Color {
        switch self {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        case .loading:
            return .accentColor
        }
    }

    var icon: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        case .loading:
            return "arrow.clockwise.circle.fill"
        }
    }
}

struct StatusMessage: Identifiable {
    let id = UUID()
    let text: String
    let type: StatusMessageType
    let duration: TimeInterval
    let timestamp: Date = Date()
}

@MainActor
class StatusBarManager: ObservableObject {
    static let shared = StatusBarManager()

    @Published var currentMessage: StatusMessage?
    @Published var isVisible: Bool = false

    private var messageQueue: [StatusMessage] = []
    private var dismissTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Public Methods

    func showMessage(_ text: String, type: StatusMessageType = .info, duration: TimeInterval = 5.0) {
        let message = StatusMessage(text: text, type: type, duration: duration)

        if currentMessage == nil {
            // No current message, show immediately
            displayMessage(message)
        } else {
            // Add to queue if there's a current message
            messageQueue.append(message)
        }
    }

    func showSuccess(_ text: String) {
        showMessage(text, type: .success)
    }

    func showError(_ text: String) {
        showMessage(text, type: .error, duration: 7.0) // Errors stay longer
    }

    func showLoading(_ text: String) {
        showMessage(text, type: .loading, duration: 30.0) // Loading stays until dismissed
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        withAnimation(.easeInOut(duration: 0.3)) {
            isVisible = false
        }

        // Clear current message after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.currentMessage = nil
            self?.processQueue()
        }
    }

    // MARK: - Private Methods

    private func displayMessage(_ message: StatusMessage) {
        // Cancel any existing timer
        dismissTimer?.invalidate()

        // Set the new message
        currentMessage = message

        // Animate in
        withAnimation(.easeInOut(duration: 0.3)) {
            isVisible = true
        }

        // Set up auto-dismiss timer
        dismissTimer = Timer.scheduledTimer(withTimeInterval: message.duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func processQueue() {
        guard !messageQueue.isEmpty else { return }

        let nextMessage = messageQueue.removeFirst()

        // Small delay before showing next message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.displayMessage(nextMessage)
        }
    }

    // MARK: - Convenience Methods for Common Messages

    func routineCreated(_ name: String) {
        showSuccess("New routine '\(name)' saved...")
    }

    func routineUpdated() {
        showSuccess("Routine updated")
    }

    func titleUpdated() {
        showSuccess("Title updated")
    }

    func descriptionUpdated() {
        showSuccess("Description saved")
    }

    func actionAdded() {
        showSuccess("Action added")
    }

    func actionRemoved() {
        showSuccess("Action removed")
    }

    func savingInProgress() {
        showLoading("Saving...")
    }

    // MARK: - Sync Status Messages

    func syncInProgress() {
        showLoading("Syncing with server...")
    }

    func syncCompleted(count: Int) {
        if count > 0 {
            showSuccess("Synced \(count) routine\(count == 1 ? "" : "s") to server")
        } else {
            showMessage("All routines are up to date", type: .info, duration: 3.0)
        }
    }

    func syncFailed(_ error: String) {
        showError("Sync failed: \(error)")
    }

    func routineSynced(_ name: String) {
        showSuccess("'\(name)' synced to server")
    }

    func routineSyncFailed(_ name: String) {
        showError("Failed to sync '\(name)'")
    }

    func offlineMode() {
        showMessage("Working offline - changes will sync when connected", type: .warning, duration: 5.0)
    }

    func backOnline() {
        showSuccess("Back online - syncing changes...")
    }

    func conflictDetected(_ routineName: String) {
        showMessage("Conflict detected for '\(routineName)' - please resolve", type: .warning, duration: 7.0)
    }
}