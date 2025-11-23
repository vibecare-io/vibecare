//
//  NetworkConfiguration.swift
//  vibecare
//
//  Helper utilities for network configuration from UserDefaults
//

import Foundation

enum NetworkConfiguration {
    /// Get the backend URL for HTTP/web services (icons, etc.)
    /// Returns the configured backend URL or default http://localhost:8080
    static func getBackendURL() -> String {
        return UserDefaults.standard.string(forKey: "backend_url") ?? "http://localhost:8080"
    }

    /// Get the gRPC URL for service communication
    /// Returns the configured gRPC URL or default grpc://localhost:50051
    static func getGRPCURL() -> String {
        return UserDefaults.standard.string(forKey: "grpc_url") ?? "grpc://localhost:50051"
    }

    /// Build an icon URL from the backend URL
    /// - Parameter iconId: The icon identifier
    /// - Returns: Full URL string for the icon (e.g., http://localhost:8080/api/icons/meditation.svg)
    static func buildIconURL(iconId: String) -> String {
        print("🔍 [NetworkConfiguration.buildIconURL] Input iconId: \(iconId)")
        let backendURL = getBackendURL().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        print("🔍 [NetworkConfiguration.buildIconURL] Backend URL: \(backendURL)")
        let finalURL = "\(backendURL)/api/icons/\(iconId).svg"
        print("🔍 [NetworkConfiguration.buildIconURL] Final URL: \(finalURL)")
        return finalURL
    }

    /// Parse gRPC URL into components
    /// - Returns: Tuple of (host, port, useTLS) or nil if invalid
    static func parseGRPCURL(_ urlString: String) -> (host: String, port: Int, useTLS: Bool)? {
        guard let url = URL(string: urlString) else { return nil }

        let useTLS = url.scheme == "grpcs"
        let host = url.host ?? "localhost"
        let port = url.port ?? (useTLS ? 50051 : 50051)

        return (host, port, useTLS)
    }
}
