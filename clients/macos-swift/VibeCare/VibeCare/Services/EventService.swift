import Foundation
import Combine
import Logging
import GRPCCore
import GRPCProtobuf
import GRPCNIOTransportHTTP2
import VCStubs

@MainActor
class EventService: ObservableObject {
    static let shared = EventService()

    // MARK: - Published Properties
    @Published var isListening = false
    @Published var connectionError: Error?
    @Published var lastEventReceived: Date?

    // MARK: - Private Properties
    private let logger = Logger(label: "com.vibecare.event-service")
    private var eventStreamTask: Task<Void, Never>?
    private var currentProfileId: String?

    // Event handlers
    private var scheduleTriggeredHandler: ((VCScheduleTriggeredEvent) -> Void)?
    private var routineExecutedHandler: ((VCRoutineExecutedEvent) -> Void)?

    private init() {
        logger.info("EventService initialized")
    }

    // MARK: - Public Methods

    /// Start listening for events for a specific profile
    func startListening(for profileId: String) async {
        guard !isListening else {
            logger.warning("Already listening for events")
            return
        }

        currentProfileId = profileId
        isListening = true
        connectionError = nil

        logger.info("Starting event listener for profile: \(profileId)")

        // Cancel any existing stream task
        eventStreamTask?.cancel()

        // Start new streaming task
        eventStreamTask = Task { [weak self] in
            await self?.listenForEvents(profileId: profileId)
        }
    }

    /// Stop listening for events
    func stopListening() {
        logger.info("Stopping event listener")

        eventStreamTask?.cancel()
        eventStreamTask = nil
        isListening = false
        currentProfileId = nil
    }

    /// Set handler for schedule triggered events
    func onScheduleTriggered(_ handler: @escaping (VCScheduleTriggeredEvent) -> Void) {
        scheduleTriggeredHandler = handler
    }

    /// Set handler for routine executed events
    func onRoutineExecuted(_ handler: @escaping (VCRoutineExecutedEvent) -> Void) {
        routineExecutedHandler = handler
    }

    // MARK: - Private Methods

    private func listenForEvents(profileId: String) async {
        do {
            let _: Void = try await GRPCClientManager.shared.withEventServiceClient { [weak self] (client: VCEventService.Client<HTTP2ClientTransport.Posix>) async throws -> Void in
                guard let self = self else { return }

                // Create subscription request
                var request = VCSubscribeEventsRequest()
                request.profileID = profileId
                // Subscribe to both schedule and routine events
                request.eventTypes = [.scheduleTriggered, .routineExecuted]

                self.logger.info("Event stream connecting for profile: \(profileId)")

                // Start streaming with onResponse handler
                try await client.subscribeEvents(request) { response in
                    self.logger.info("Event stream connected for profile: \(profileId)")

                    // Process incoming events
                    for try await event in response.messages {
                        await self.handleDispatchEvent(event)
                    }

                    self.logger.info("Event stream ended normally")
                    return Void()
                }
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.connectionError = error
                self?.isListening = false
                self?.logger.error("Event stream error: \(error)")
            }
        }
    }

    private func handleDispatchEvent(_ event: VCDispatchEvent) async {
        logger.info("Received event of type: \(event.eventType)")

        await MainActor.run { [weak self] in
            self?.lastEventReceived = Date()
        }

        // Handle based on event type
        switch event.payload {
        case .scheduleTriggered(let scheduleEvent):
            await handleScheduleTriggered(scheduleEvent)

        case .routineExecuted(let routineEvent):
            await handleRoutineExecuted(routineEvent)

        case .none:
            logger.warning("Received event with no payload")
        }
    }

    private func handleScheduleTriggered(_ event: VCScheduleTriggeredEvent) async {
        logger.info("Schedule triggered: \(event.routineName) (Schedule ID: \(event.scheduleID))")

        await MainActor.run { [weak self] in
            // Call the registered handler
            self?.scheduleTriggeredHandler?(event)

            // Show VibeNotify notification (works in foreground and background)
            NotificationManager.shared.showScheduleNotification(for: event)
        }
    }

    private func handleRoutineExecuted(_ event: VCRoutineExecutedEvent) async {
        logger.info("Routine executed: \(event.routineName) (Routine ID: \(event.routineID))")

        await MainActor.run { [weak self] in
            // Call the registered handler
            self?.routineExecutedHandler?(event)
        }
    }

    // MARK: - Reconnection Support

    func reconnectIfNeeded() async {
        guard let profileId = currentProfileId, !isListening else { return }

        logger.info("Attempting to reconnect event stream")
        await startListening(for: profileId)
    }
}

