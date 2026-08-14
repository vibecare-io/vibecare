import Testing
import Foundation
@testable import VCPluginSDK

@Test func servesHealthOnAnEphemeralPortOverAPersistentConnection() async throws {
    let router = VCRouter()
    await router.handle("/health") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "application/json"])
        try await w.write(Data(#"{"status":"ok","detail":""}"#.utf8))
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    #expect(port > 0)

    // A URLSession reuses connections by default, so two sequential requests
    // over one session exercise the keep-alive path the health prober uses.
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<2 {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("\"status\":\"ok\""))
    }
    await server.stop()
}

@Test func unknownPathIs404() async throws {
    let router = VCRouter()
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/nope")!
    let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 404)
    await server.stop()
}

@Test func prefixRoutesMatchSubpaths() async throws {
    let router = VCRouter()
    await router.handlePrefix("/api/tasks/") { req, w in
        try await w.writeHead(status: 200, headers: [:])
        try await w.write(Data(req.path.utf8))
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/api/tasks/abc/toggle")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect(String(decoding: data, as: UTF8.self) == "/api/tasks/abc/toggle")
    await server.stop()
}

@Test func streamsChunksWithoutClosing() async throws {
    // Proves the writer can emit before finishing — the property MJPEG and
    // SSE depend on. Without it the preview hangs.
    let router = VCRouter()
    await router.handle("/stream") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "text/plain"])
        for i in 0..<3 {
            try await w.write(Data("chunk\(i)\n".utf8))
        }
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/stream")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect(String(decoding: data, as: UTF8.self) == "chunk0\nchunk1\nchunk2\n")
    await server.stop()
}
