import Foundation

public struct VCRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data
}

/// Streaming response interface. Handlers write rather than return, because
/// /preview.mjpeg and /api/events never complete — a returned-value API
/// cannot express them.
public protocol VCResponseWriter: Sendable {
    func writeHead(status: Int, headers: [String: String]) async throws
    func write(_ chunk: Data) async throws
    func finish() async throws
}

public typealias VCHandler = @Sendable (VCRequest, any VCResponseWriter) async throws -> Void

public actor VCRouter {
    private var exact: [String: VCHandler] = [:]
    private var prefixes: [(String, VCHandler)] = []

    public init() {}

    public func handle(_ path: String, _ h: @escaping VCHandler) {
        exact[path] = h
    }

    /// Longest prefix wins, so "/api/tasks/" beats "/api/" regardless of
    /// registration order.
    public func handlePrefix(_ prefix: String, _ h: @escaping VCHandler) {
        prefixes.append((prefix, h))
        prefixes.sort { $0.0.count > $1.0.count }
    }

    public func route(_ path: String) -> VCHandler? {
        if let h = exact[path] { return h }
        for (prefix, h) in prefixes where path.hasPrefix(prefix) { return h }
        return nil
    }
}
