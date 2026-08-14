import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
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
    //
    // NOTE: this is an end-to-end smoke check, not the keep-alive guard —
    // URLSession's own connection pool validates a socket for liveness
    // before reuse and silently opens a fresh one if the server closed it,
    // so a close-per-response regression would NOT go red here. The actual
    // guard is `keepAliveIsProvenOnASingleRawSocket`, which talks to a raw
    // BSD socket below the pool.
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

/// The real keep-alive guard. `URLSession` (and `curl`, which behaves the
/// same way) validate a pooled connection for liveness before reusing it,
/// so they silently reconnect instead of failing when a server regresses to
/// closing after every response — see
/// `servesHealthOnAnEphemeralPortOverAPersistentConnection`'s note. This
/// test drives one raw BSD socket directly, below any client-side pooling,
/// so a close-per-response server genuinely fails it: the second read
/// returns EOF (0 bytes) instead of a second HTTP/1.1 response.
@Test func keepAliveIsProvenOnASingleRawSocket() async throws {
    let router = VCRouter()
    await router.handle("/health") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "application/json"])
        try await w.write(Data(#"{"status":"ok","detail":""}"#.utf8))
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }

    // A short read timeout so a server that hangs (rather than closing)
    // fails this test instead of hanging the whole suite.
    var readTimeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
    // Turn a write to an already-closed peer into a plain EPIPE return value
    // instead of a process-killing SIGPIPE.
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(connectResult == 0)

    let requestBytes = Array("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)

    func sendRequest() {
        var sent = 0
        requestBytes.withUnsafeBufferPointer { buf in
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    // Reads until the chunked-body terminator (`0\r\n\r\n`) appears after
    // the header block, or until `read` returns <= 0 (EOF/error/timeout —
    // exactly what a close-per-response regression produces).
    func readResponse() -> String {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let headerEnd = result.range(of: Data("\r\n\r\n".utf8)),
               result[headerEnd.upperBound...].range(of: Data("0\r\n\r\n".utf8)) != nil {
                break
            }
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            guard n > 0 else { break }
            result.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: result, as: UTF8.self)
    }

    sendRequest()
    let first = readResponse()
    #expect(first.hasPrefix("HTTP/1.1 200"), "first response on the raw socket: \(first)")

    sendRequest()
    let second = readResponse()
    #expect(second.hasPrefix("HTTP/1.1 200"), "second response on the SAME raw socket: \(second)")

    await server.stop()
}
