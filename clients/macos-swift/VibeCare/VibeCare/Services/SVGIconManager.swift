//
//  SVGIconManager.swift
//  vibecare
//
//  Created by Claude Code on 2025-11-06.
//

import Foundation
import Logging
import VCStubs
import GRPCCore

/// Manages loading and accessing SVG icons from backend
@MainActor
class SVGIconManager: ObservableObject {
    static let shared = SVGIconManager()

    private let logger = Logger(label: "com.vibecare.icon-manager")
    private let grpcClient: GRPCClientManager

    @Published private(set) var icons: [SVGIcon] = []
    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var loadError: Error?

    private init(grpcClient: GRPCClientManager = .shared) {
        self.grpcClient = grpcClient
    }

    /// Load icons from backend via gRPC
    func loadIcons(category: IconCategory? = nil) async throws {
        logger.info("Loading SVG icons from backend", metadata: [
            "category": "\(category?.rawValue ?? "all")"
        ])

        isLoaded = false
        loadError = nil

        do {
            // Create request
            var request = VCListIconsRequest()
            if let category = category {
                request.category = category.rawValue
            }

            // Make gRPC call
            let clientRequest = ClientRequest(message: request)
            let response = try await grpcClient.withIconServiceClient { client in
                try await client.listIcons(request: clientRequest)
            }

            // Get backend base URL for constructing icon URLs
            let host = UserDefaults.standard.string(forKey: "grpc_host") ?? "localhost"
            let port = UserDefaults.standard.integer(forKey: "grpc_port") != 0
                ? UserDefaults.standard.integer(forKey: "grpc_port")
                : 50051
            let useTLS = UserDefaults.standard.bool(forKey: "grpc_use_tls")
            let scheme = useTLS ? "https" : "http"

            guard let baseURL = URL(string: "\(scheme)://\(host):\(port)") else {
                throw IconError.invalidBackendURL
            }

            // Convert to Swift models
            self.icons = response.icons.map { SVGIcon(from: $0, baseURL: baseURL) }
                .sorted { $0.name < $1.name }

            self.isLoaded = true
            self.loadError = nil

            logger.info("Successfully loaded \(self.icons.count) icons from backend")

        } catch {
            self.loadError = error
            logger.error("Failed to load icons from backend", metadata: [
                "error": "\(error)"
            ])
            throw error
        }
    }

    /// Get an icon by its ID
    func icon(withId id: String) -> SVGIcon? {
        return icons.first { $0.id == id }
    }

    /// Get the URL for an icon by ID
    func url(forIconId id: String) -> URL? {
        return icon(withId: id)?.iconURL
    }

    /// Get icons for a specific category
    func icons(for category: IconCategory) -> [SVGIcon] {
        return icons.filter { $0.category == category }
    }

    /// Search icons by query (name or keywords)
    func searchIcons(query: String) -> [SVGIcon] {
        guard !query.isEmpty else { return icons }
        return icons.filter { $0.matches(searchQuery: query) }
    }

    /// Get all categories that have icons
    func availableCategories() -> [IconCategory] {
        let categoriesInUse = Set(icons.map { $0.category })
        return IconCategory.allCases
            .filter { categoriesInUse.contains($0) }
            .sorted { $0.order < $1.order }
    }

    /// Reload icons from backend
    func reload() async {
        logger.info("Reloading icons from backend...")
        icons = []
        isLoaded = false
        loadError = nil
        try? await loadIcons()
    }
}

// MARK: - Error Types

extension SVGIconManager {
    enum IconError: LocalizedError {
        case invalidBackendURL
        case loadFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidBackendURL:
                return "Invalid backend URL configuration"
            case .loadFailed(let error):
                return "Failed to load icons: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Preview Support

#if DEBUG
extension SVGIconManager {
    /// Create a mock manager for SwiftUI previews
    static func mock(withIcons icons: [SVGIcon]) -> SVGIconManager {
        let manager = SVGIconManager()
        manager.icons = icons
        manager.isLoaded = true
        manager.loadError = nil
        return manager
    }

    /// Sample icons for previews
    static var sampleIcons: [SVGIcon] {
        return [
            SVGIcon(
                id: "meditation",
                name: "Meditation",
                category: .health,
                filename: "meditation.svg",
                keywords: ["meditation", "mindfulness", "zen"]
            ),
            SVGIcon(
                id: "water",
                name: "Water",
                category: .health,
                filename: "water.svg",
                keywords: ["water", "hydration", "drink"]
            ),
            SVGIcon(
                id: "focus",
                name: "Focus",
                category: .productivity,
                filename: "focus.svg",
                keywords: ["focus", "target", "concentration"]
            ),
            SVGIcon(
                id: "notification",
                name: "Notification",
                category: .communication,
                filename: "notification.svg",
                keywords: ["notification", "bell", "alert"]
            )
        ]
    }
}
#endif
