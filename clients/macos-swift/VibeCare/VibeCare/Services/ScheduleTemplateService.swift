import Foundation
import Logging
import VCStubs
import GRPCCore

/// Service for fetching schedule templates from backend
@MainActor
class ScheduleTemplateService: ObservableObject {
    @Published var templates: [RoutineScheduleTemplate] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let logger = Logger(label: "com.vibecare.template-service")
    private let grpcClient: GRPCClientManager

    init(grpcClient: GRPCClientManager = .shared) {
        self.grpcClient = grpcClient
    }

    /// Load templates from backend, optionally filtered by category
    func loadTemplates(category: TemplateCategory? = nil) async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }

        logger.info("Loading schedule templates from backend", metadata: [
            "category": "\(category?.rawValue ?? "all")"
        ])

        do {
            // Create request
            var request = VCListScheduleTemplatesRequest()
            if let category = category {
                request.category = category.toProto()
            }

            // Make gRPC call using new gRPC client format
            let clientRequest = ClientRequest(message: request)
            let response = try await grpcClient.withTemplateServiceClient { client in
                try await client.listScheduleTemplates(request: clientRequest)
            }

            // Convert to Swift models
            self.templates = response.templates.map { RoutineScheduleTemplate(from: $0) }

            logger.info("Successfully loaded templates", metadata: [
                "count": "\(self.templates.count)"
            ])

        } catch {
            self.error = error
            logger.error("Failed to load templates", metadata: [
                "error": "\(error)"
            ])
            throw error
        }
    }

    /// Reload templates
    func reload() async {
        try? await loadTemplates()
    }
}
