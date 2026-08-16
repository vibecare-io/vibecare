import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

public enum VCHTTPError: Error, CustomStringConvertible {
    case noPort
    /// Thrown by `write(_:)` when called before `writeHead`. Silently
    /// no-oping here used to leave the client hanging with no head and no
    /// body and no error — worse than a throw in a service core
    /// health-probes.
    case writeBeforeHead

    public var description: String {
        switch self {
        case .noPort:
            return "VCHTTPServer: the OS did not assign a port to the bound socket"
        case .writeBeforeHead:
            return "VCResponseWriter.write(_:) was called before writeHead(status:headers:) — no status line has been sent yet"
        }
    }
}

/// HTTP/1.1 on 127.0.0.1:0. Keep-alive is left ON: the kernel's health
/// prober (health.go:135) uses a shared http.Client with the default
/// transport and holds an idle persistent connection. A close-per-response
/// server fails those probes intermittently.
public actor VCHTTPServer {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init() {}

    public func start(router: VCRouter) async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(VCHTTPHandler(router: router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Bind before Register: RegisterReq.http_port must carry the port the
        // OS actually assigned, and the proxy targets it the instant core
        // marks the plugin up.
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        guard let port = channel.localAddress?.port else { throw VCHTTPError.noPort }
        return port
    }

    public func stop() async {
        try? await channel?.close().get()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
    }
}

/// Adapts a NIO `Channel` to `VCResponseWriter`. An actor rather than a
/// plain class so the head-written/finished bookkeeping that decides
/// 404-vs-500-vs-close-only is never torn by concurrent access — a handler
/// is only ever driven by one `Task`, but the type still has to satisfy
/// `Sendable` to cross into that `Task` in the first place.
actor VCNIOResponseWriter: VCResponseWriter {
    private let channel: Channel
    private let version: HTTPVersion
    private let requestIsKeepAlive: Bool

    private(set) var headWritten = false
    private var finished = false

    init(channel: Channel, version: HTTPVersion, requestIsKeepAlive: Bool) {
        self.channel = channel
        self.version = version
        self.requestIsKeepAlive = requestIsKeepAlive
    }

    func writeHead(status: Int, headers: [String: String]) async throws {
        guard !headWritten else { return }
        headWritten = true

        var httpHeaders = HTTPHeaders()
        for (name, value) in headers { httpHeaders.add(name: name, value: value) }
        // The encoder framing (configureHTTPServerPipeline) fills in
        // Transfer-Encoding/Content-Length; we only need to be honest about
        // whether the connection survives this response.
        if !requestIsKeepAlive {
            httpHeaders.replaceOrAdd(name: "Connection", value: "close")
        }

        let head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status), headers: httpHeaders)
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
    }

    func write(_ chunk: Data) async throws {
        guard headWritten else { throw VCHTTPError.writeBeforeHead }
        guard !finished else { return }
        var buffer = channel.allocator.buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        if !requestIsKeepAlive {
            try? await channel.close().get()
        }
    }

    /// Emits a bodyless response for the paths that never reach a
    /// user-supplied handler (404 route miss, 500 before-any-write). Safe
    /// to call at most once: if a head is already on the wire this is a
    /// deliberate no-op, since the status line can't be retroactively
    /// changed.
    func sendBodylessStatus(_ status: Int) async {
        guard !headWritten else { return }
        try? await writeHead(status: status, headers: [:])
        try? await finish()
    }

    /// Bytes are already on the wire and the handler threw. We cannot send
    /// a second status line, so the only honest move is to log (by the
    /// caller) and drop the connection.
    func abortAfterPartialWrite() async {
        finished = true
        try? await channel.close().get()
    }
}

/// Accumulates one HTTP/1.1 request, resolves it against `VCRouter`, and
/// hands off to the matched handler through a streaming `VCResponseWriter`.
///
/// Routing and the handler body are both async, but `ChannelInboundHandler`
/// callbacks are synchronous NIO-event-loop calls, so `channelRead` only
/// gathers request parts; on `.end` it captures the plain `Channel` (safe to
/// use off the event loop — NIO hops internally) and hands off to an
/// unstructured `Task`. `ChannelHandlerContext` itself is never captured
/// past the synchronous call that receives it.
///
/// Requests on one keep-alive connection are chained, not merely spawned:
/// each new `Task` first awaits the previous request's `Task` before doing
/// any routing or writing. Without this, two pipelined requests on the same
/// socket could have their handler `Task`s interleave writes on the shared
/// `Channel`, violating RFC 7230 §6.3.2 ("a server MUST send its responses
/// in the same order that the requests were received"). No mainstream
/// client pipelines by default, so this was unlikely to fire — but silent
/// out-of-order responses on a rare pipelining client would have been
/// miserable to diagnose. One consequence: a streaming handler (MJPEG, SSE)
/// now holds up any later request queued behind it on the same connection
/// until it finishes — correct HTTP/1.1 semantics, not a bug.
///
/// `@unchecked Sendable` because NIO only ever touches this instance from
/// the single event-loop thread that owns its channel — the same guarantee
/// `configureHTTPServerPipeline` relies on for every other handler in the
/// pipeline. Its mutable state (`pendingHead`/`pendingBody`/`lastRequestTask`)
/// never crosses threads; only the immutable `Channel` handed to each
/// per-request `Task` does, and `Channel` is itself safe to use off-thread.
final class VCHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: VCRouter

    private var pendingHead: HTTPRequestHead?
    private var pendingBody: ByteBuffer?

    /// The most recently spawned per-request `Task` on this connection.
    /// Each new request's `Task` awaits this before doing anything, so
    /// requests on one channel are always serviced — and, crucially,
    /// written to the wire — in the order they arrived.
    private var lastRequestTask: Task<Void, Never>?

    init(router: VCRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
            pendingBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var chunk):
            pendingBody?.writeBuffer(&chunk)

        case .end:
            guard let head = pendingHead else { return }
            let body = pendingBody.map { Data($0.readableBytesView) } ?? Data()
            pendingHead = nil
            pendingBody = nil

            let (path, query) = Self.parseURI(head.uri)
            let request = VCRequest(method: head.method.rawValue, path: path, query: query, body: body)
            let channel = context.channel
            let router = self.router
            let writer = VCNIOResponseWriter(channel: channel, version: head.version, requestIsKeepAlive: head.isKeepAlive)
            let previous = lastRequestTask

            lastRequestTask = Task {
                await previous?.value

                let matched = await router.route(path)
                guard let matched else {
                    await writer.sendBodylessStatus(404)
                    return
                }
                do {
                    try await matched(request, writer)
                } catch {
                    // vcLog, never FileHandle.standardError.write(_:) — see
                    // VCLog.swift. This is the request ERROR path, so it runs
                    // exactly when something has already gone wrong, and a
                    // closed stderr would turn a handled 500 into an
                    // uncatchable abort that core charges as a failed start.
                    if await writer.headWritten {
                        vcLog("handler for \(path) threw after writing a response head, closing connection: \(error)")
                        await writer.abortAfterPartialWrite()
                    } else {
                        vcLog("handler for \(path) threw before writing anything: \(error)")
                        await writer.sendBodylessStatus(500)
                    }
                }
            }
        }
    }

    /// `URLComponents` happily parses a path+query string with no scheme or
    /// host, which is all an HTTP/1.1 request line ever gives us.
    private static func parseURI(_ uri: String) -> (path: String, query: [String: String]) {
        guard let components = URLComponents(string: uri) else { return (uri, [:]) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (components.path, query)
    }
}
