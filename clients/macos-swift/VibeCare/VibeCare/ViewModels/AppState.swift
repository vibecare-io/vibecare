import SwiftUI
import Combine
import Logging
//import Logging

@MainActor
public class AppState: ObservableObject {
    public static let shared = AppState()

    // MARK: - Published Properties
    @Published public var currentProfile: Profile?
    @Published public var profiles: [Profile] = []
    @Published public var isConnected: Bool = false
    @Published public var showProfileSelector: Bool = false
    @Published public var showConnectionError: Bool = false
    @Published public var isLoading: Bool = false

    // MARK: - Services
    private let logger = Logger(label: "com.vibecare.appstate")
    private var cancellables = Set<AnyCancellable>()
    private let eventService = EventService.shared
    private var notificationManager: NotificationManager?

    private init() {
        loadCachedProfile()
        setupEventHandlers()
    }

    // MARK: - Public Methods
    public func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Load profiles from backend
            let profileService = ProfileService()
            let fetchedProfiles = try await profileService.listProfiles()

            await MainActor.run {
                self.profiles = fetchedProfiles

                // If no current profile, set the first one or prompt for creation
                if currentProfile == nil {
                    if let firstProfile = fetchedProfiles.first {
                        currentProfile = firstProfile
                        UserDefaults.standard.set(firstProfile.id, forKey: "currentProfileId")
                    } else {
                        showProfileSelector = true
                    }
                }
            }

            logger.info("Successfully loaded \(fetchedProfiles.count) profiles")
        } catch {
            logger.error("Failed to load initial data: \(error)")
            await MainActor.run {
                showConnectionError = true
            }
        }
    }

    func selectProfile(_ profile: Profile) {
        // Stop listening to previous profile events
        if currentProfile != nil {
            Task {
                eventService.stopListening()
            }
        }

        currentProfile = profile
        UserDefaults.standard.set(profile.id, forKey: "currentProfileId")
        showProfileSelector = false

        logger.info("Selected profile: \(profile.name)")

        // Start listening to new profile events
        Task {
            await eventService.startListening(for: profile.id)
        }

        // Notify other view models about profile change
        NotificationCenter.default.post(
            name: .profileChanged,
            object: profile
        )
    }

    func createProfile(name: String, email: String) async {
        do {
            let profileService = ProfileService()
            let newProfile = try await profileService.createProfile(
                name: name,
                email: email,
                preferences: [:]
            )

            await MainActor.run {
                profiles.append(newProfile)
                selectProfile(newProfile)
            }

            logger.info("Created new profile: \(name)")
        } catch {
            logger.error("Failed to create profile: \(error)")
            await MainActor.run {
                showConnectionError = true
            }
        }
    }

    // MARK: - Private Methods

    private func loadCachedProfile() {
        if let profileId = UserDefaults.standard.string(forKey: "currentProfileId") {
            // Will be loaded from backend in loadInitialData
            logger.info("Found cached profile ID: \(profileId)")
        }
    }

    private func setupEventHandlers() {
        // Handle schedule triggered events
        eventService.onScheduleTriggered { [weak self] event in
            self?.logger.info("Schedule triggered event received: \(event.routineName)")

            // Post notification for any views that need to update
            NotificationCenter.default.post(
                name: Notification.Name("ScheduleTriggered"),
                object: nil,
                userInfo: [
                    "scheduleId": event.scheduleID,
                    "routineId": event.routineID,
                    "routineName": event.routineName
                ]
            )
        }

        // Handle routine executed events
        eventService.onRoutineExecuted { [weak self] event in
            self?.logger.info("Routine executed event received: \(event.routineName)")

            // Post notification for any views that need to update
            NotificationCenter.default.post(
                name: Notification.Name("RoutineExecuted"),
                object: nil,
                userInfo: [
                    "routineId": event.routineID,
                    "routineName": event.routineName
                ]
            )
        }

        // Listen for open routine notifications from notification actions
        NotificationCenter.default.publisher(for: Notification.Name("OpenRoutine"))
            .compactMap { $0.userInfo?["routineId"] as? String }
            .sink { [weak self] routineId in
                self?.logger.info("Opening routine from notification: \(routineId)")
                // TODO: Navigate to routine detail view
            }
            .store(in: &cancellables)
    }

    // MARK: - App Lifecycle

    func handleAppBecameActive() {
        // Reconnect event stream if needed
        if currentProfile != nil {
            Task {
                await eventService.reconnectIfNeeded()
            }
        }
    }

    func handleAppWillResignActive() {
        // Optionally pause event listening when app goes to background
        // For now, keep listening for notifications
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let profileChanged = Notification.Name("profileChanged")
}
