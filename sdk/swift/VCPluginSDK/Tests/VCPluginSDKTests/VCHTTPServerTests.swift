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

@Test func handlerThrowingBeforeAnyWriteIs500() async throws {
    struct Boom: Error {}
    let router = VCRouter()
    await router.handle("/boom") { _, _ in
        throw Boom()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/boom")!
    let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 500)
    await server.stop()
}

/// The throw-after-bytes-on-the-wire path can't be observed through
/// `URLSession`: it needs to see the raw bytes to prove (a) the partial
/// response actually reached the client, (b) the connection was closed
/// rather than hung, and (c) no second status line followed the first —
/// exactly the tool built for `keepAliveIsProvenOnASingleRawSocket`.
@Test func handlerThrowingAfterWritingHeadClosesWithoutASecondHead() async throws {
    struct Boom: Error {}
    let router = VCRouter()
    await router.handle("/partial") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "text/plain"])
        try await w.write(Data("partial-chunk\n".utf8))
        throw Boom()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)

    let fd = openRawLoopbackSocket(port: port)
    #expect(fd >= 0)
    defer { close(fd) }

    sendRaw(fd, "GET /partial HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    // No terminator to look for: the handler never called finish(), so the
    // only way this loop ends is the server closing the connection (EOF)
    // or the read timing out (which would mean it hung instead — also a
    // failure, just a slower one).
    let data = readRaw(fd, until: { _ in false })
    let text = String(decoding: data, as: UTF8.self)

    #expect(text.hasPrefix("HTTP/1.1 200"), "expected the head written before the throw to be on the wire: \(text)")
    #expect(text.contains("partial-chunk"), "expected the chunk written before the throw to be on the wire: \(text)")
    let statusLineCount = text.components(separatedBy: "HTTP/1.1 ").count - 1
    #expect(statusLineCount == 1, "expected exactly one response head (no retroactive second status line), saw \(statusLineCount): \(text)")

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

    let fd = openRawLoopbackSocket(port: port)
    #expect(fd >= 0)
    defer { close(fd) }

    sendRaw(fd, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    let first = String(decoding: readRaw(fd, until: hasChunkedTerminatorAfterHeaders), as: UTF8.self)
    #expect(first.hasPrefix("HTTP/1.1 200"), "first response on the raw socket: \(first)")

    sendRaw(fd, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    let second = String(decoding: readRaw(fd, until: hasChunkedTerminatorAfterHeaders), as: UTF8.self)
    #expect(second.hasPrefix("HTTP/1.1 200"), "second response on the SAME raw socket: \(second)")

    await server.stop()
}

// MARK: - Raw-socket test helpers

/// Opens one connected TCP socket to `127.0.0.1:port`, deliberately below
/// any HTTP client's connection pool (which would otherwise validate and
/// silently replace a dead socket, masking exactly the regressions these
/// tests exist to catch).
///
/// Sets a short read timeout so a server that hangs fails the calling test
/// instead of hanging the whole suite, and SO_NOSIGPIPE so writing to an
/// already-closed peer returns EPIPE instead of killing the process with
/// SIGPIPE.
private func openRawLoopbackSocket(port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return fd }

    var readTimeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
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
    guard connectResult == 0 else {
        close(fd)
        return -1
    }
    return fd
}

private func sendRaw(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var sent = 0
    bytes.withUnsafeBufferPointer { buf in
        while sent < buf.count {
            let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
            guard n > 0 else { return }
            sent += n
        }
    }
}

/// Reads until `isComplete` says the accumulated bytes form a whole
/// response, or the peer closes / the read times out (`read` returning
/// `<= 0`) — which is itself a meaningful, test-relevant outcome rather
/// than an error to hide.
private func readRaw(_ fd: Int32, until isComplete: (Data) -> Bool) -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !isComplete(result) {
        let n = buffer.withUnsafeMutableBufferPointer { ptr in
            read(fd, ptr.baseAddress, ptr.count)
        }
        guard n > 0 else { break }
        result.append(contentsOf: buffer[0..<n])
    }
    return result
}

/// True once a full chunked-encoded HTTP response (headers + the `0\r\n\r\n`
/// terminator) has been accumulated.
private func hasChunkedTerminatorAfterHeaders(_ data: Data) -> Bool {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
    return data[headerEnd.upperBound...].range(of: Data("0\r\n\r\n".utf8)) != nil
}
