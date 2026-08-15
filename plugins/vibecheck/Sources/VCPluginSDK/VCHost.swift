import Dispatch
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import SwiftProtobuf
import VCKStubs

/// The plugin's whole control plane.
///
/// A plugin is ALWAYS the gRPC client and NEVER a gRPC server: it dials core
/// over the unix socket named by `VIBECARE_SOCKET` and calls three RPCs on
/// `vibecare.kernel.plugin.v1.PluginHost`. `Register` is server-streaming and
/// long-lived; `Publish` and `Alert` are unary.
///
/// Nothing in this type ever terminates the process. `supervisor.go` charges
/// any unrequested exit as a failed start and parks the plugin in
/// `StateFailed` after `maxFailedStarts` (5) of them, recoverable only by a
/// manual restart from the dashboard. So a ready timeout, a `NOT_FOUND`
/// registration, and an unreachable socket are all *retried in place*.
public actor VCHost {
    public nonisolated let id: String
    public nonisolated let dataDir: URL

    private let router: VCRouter
    private let socketPath: String

    private var server: VCHTTPServer?
    /// The port the OS actually assigned, and the one core's proxy targets.
    public private(set) var httpPort: Int = 0

    private var ladder = VCReconnectLadder()
    private var shutdownHooks: [@Sendable () async -> Void] = []
    private var didRunShutdown = false
    private var stopped = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    private var healthProbe: @Sendable () -> (status: String, detail: String) = { ("ok", "") }
    private var eventContinuations: [UUID: AsyncStream<VCEvent>.Continuation] = [:]

    /// Non-nil for the whole lifetime of one gRPC client, which spans many
    /// Register sessions. `Publish` and `Alert` need only a live connection,
    /// not a live Register stream — `rpc.go:166-172, 194-200` check the
    /// manifest id and nothing else — so both keep working across a reconnect.
    private var client: (any VCKPluginHost.ClientProtocol)?

    /// Whether the *current* session has seen `CoreMsg.ready`.
    private var sawReady = false
    private var sessionTask: Task<Void, Never>?
    private var signalSource: (any DispatchSourceProtocol)?

    /// `Publish`/`Alert` deadline. Neither has one in the Go SDK, so both can
    /// block forever against a wedged core; a detector publishing at frame
    /// rate would pile up tasks until the process dies.
    private static let callDeadline: Duration = .seconds(5)

    /// How long one session waits for `CoreMsg.ready` before abandoning the
    /// attempt and re-dialling.
    ///
    /// This must sit just *inside* `supervisor.go`'s 10 s `registrationTimeout`
    /// (measured from spawn, after which core SIGKILLs a plugin that has not
    /// registered) — and nowhere near it. Do not tighten this. Any budget
    /// shorter than core's own patience is a self-imposed livelock: if core
    /// ever takes longer than the budget to answer, every attempt is torn down
    /// at the budget and the plugin can never register at all, even though
    /// core would have accepted the registration it just threw away.
    private static let readyBudget: Duration = .seconds(8)

    /// Sessions that never reach `Ready` before the whole gRPC client is torn
    /// down and rebuilt. The channel is supposed to re-dial the socket by
    /// itself, but this transport is new to this repo; this is the escape
    /// hatch if it ever wedges rather than reconnecting.
    private static let rebuildClientAfterDeadSessions = 5

    /// Total budget for running every shutdown hook, shared across all of
    /// them. Comfortably inside `supervisor.go`'s 5 s `shutdownGrace` — the
    /// window between core's SIGTERM and its SIGKILL — so the listener still
    /// gets stopped and `waitForShutdown()` still returns even if a hook
    /// wedges.
    private static let shutdownHookBudget: Duration = .seconds(2)

    private init(env: VCEnvironment, router: VCRouter) {
        self.id = env.pluginID
        self.dataDir = env.dataDir
        self.socketPath = env.socketPath
        self.router = router
    }

    // MARK: - Startup

    /// Startup order is mandatory:
    ///   1. install `/health`
    ///   2. bind and *accept*
    ///   3. trap SIGTERM
    ///   4. `Register` with the bound port
    ///
    /// Core's proxy targets the port the instant it marks the plugin up, so a
    /// bound-but-not-accepting socket serves 502s instead of the down page,
    /// and `health.go`'s prober fails a plugin whose `/health` route was
    /// installed after registration.
    ///
    /// Throws only if the HTTP listener cannot be brought up — a programming
    /// error. A registration that core refuses is *not* an error here: it is
    /// retried in place, forever, without exiting.
    public static func connect(env: VCEnvironment, router: VCRouter) async throws -> VCHost {
        let host = VCHost(env: env, router: router)
        await host.installHealthRoute()

        let server = VCHTTPServer()
        let port = try await server.start(router: router)
        await host.adopt(server: server, port: port)

        // Before the session task, so a SIGTERM that arrives during the very
        // first dial still runs hooks instead of killing the process outright.
        await host.trapTermination()
        await host.startSessionLoop()
        return host
    }

    private func adopt(server: VCHTTPServer, port: Int) {
        self.server = server
        self.httpPort = port
    }

    // MARK: - Health

    /// `/health` is what `health.go` polls; a plugin that never sets a probe
    /// still answers 200 `{"status":"ok"}`.
    private func installHealthRoute() async {
        await router.handle("/health") { [self] _, writer in
            let body = await self.currentHealth()
            let data = (try? JSONEncoder().encode(body)) ?? Data(#"{"status":"ok"}"#.utf8)
            try await writer.writeHead(
                status: 200,
                headers: ["Content-Type": "application/json", "Content-Length": "\(data.count)"]
            )
            try await writer.write(data)
            try await writer.finish()
        }
    }

    private func currentHealth() -> VCHealthBody {
        let (status, detail) = healthProbe()
        // `normalized()` drops a detail carried alongside "ok": core force-
        // clears it on any transition to up (health.go:179-181), so emitting
        // one only misleads whoever reads the plugin's own /health directly.
        return VCHealthBody(status: status, detail: detail).normalized()
    }

    public func setHealth(_ probe: @escaping @Sendable () -> (status: String, detail: String)) {
        healthProbe = probe
    }

    // MARK: - Events

    /// A fan-out subscription to everything core delivers on the Register
    /// stream, including the reserved `_core.demand.v1` topic. Finishes when
    /// the host shuts down, which is what lets a composition root treat the
    /// stream as the process's lifetime.
    public func events() -> AsyncStream<VCEvent> {
        let (stream, continuation) = AsyncStream<VCEvent>.makeStream(
            of: VCEvent.self,
            bufferingPolicy: .bufferingNewest(512)
        )
        guard !stopped else {
            continuation.finish()
            return stream
        }
        let key = UUID()
        eventContinuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.dropContinuation(key) }
        }
        return stream
    }

    private func dropContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }

    private func deliver(_ e: VCKEvent) {
        // `ts` stays optional rather than defaulting to now: a plugin that
        // windows on event time needs to know core's clock from its own.
        let ev = VCEvent(topic: e.topic, payload: e.payload, ts: e.hasTs ? e.ts.date : nil)
        for continuation in eventContinuations.values {
            continuation.yield(ev)
        }
    }

    // MARK: - Outbound RPCs

    public func publish(topic: String, payload: Data) async throws {
        guard let client else { throw VCHostError.notConnected }
        var event = VCKEvent()
        event.topic = topic
        event.payload = payload
        event.ts = Google_Protobuf_Timestamp(date: Date())
        _ = try await client.publish(
            event,
            metadata: Self.attribution(id),
            options: Self.deadlinedOptions
        )
    }

    public func alert(_ a: VCAlert) async throws {
        guard let client else { throw VCHostError.notConnected }
        var req = VCKAlertReq()
        req.title = a.title
        req.body = a.body
        req.level = a.level
        req.actions = a.actions.map {
            var action = VCKAlertAction()
            action.label = $0.label
            action.url = $0.url
            return action
        }
        _ = try await client.alert(
            req,
            metadata: Self.attribution(id),
            options: Self.deadlinedOptions
        )
    }

    /// Core's `callerID` (rpc.go:247-256) answers `Unauthenticated` to any
    /// `Publish`/`Alert` without this header. `Register` doesn't need it —
    /// core reads the id out of the message body there — but sending it on
    /// every call is harmless and keeps one code path.
    private static func attribution(_ id: String) -> Metadata {
        var md = Metadata()
        md.addString(id, forKey: "x-vibecare-plugin-id")
        return md
    }

    private static var deadlinedOptions: CallOptions {
        var options = CallOptions.defaults
        options.timeout = callDeadline
        return options
    }

    // MARK: - Shutdown

    /// Hooks run once, on whichever of `CoreMsg.shutdown` and SIGTERM arrives
    /// first. A hook registered *after* shutdown already ran is executed
    /// immediately rather than dropped: SIGTERM can land in the window between
    /// `connect()` returning and the composition root registering its hooks,
    /// and the Go SDK's `sync.Once` silently loses every hook in that case.
    public func onShutdown(_ hook: @escaping @Sendable () async -> Void) {
        guard !didRunShutdown else {
            Task { await hook() }
            return
        }
        shutdownHooks.append(hook)
    }

    /// Returns once the host has shut down. This — not `exit()` — is how a
    /// composition root ends the process: `main` awaits it, runs off the end,
    /// and the process exits normally. Nothing in this SDK calls `exit()`,
    /// because `supervisor.go` cannot tell an SDK-initiated exit from a crash.
    public func waitForShutdown() async {
        guard !didRunShutdown else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func runShutdown() async {
        guard !didRunShutdown else { return }
        didRunShutdown = true
        stopped = true

        let hooks = shutdownHooks
        shutdownHooks.removeAll()
        await drainShutdownHooks(hooks)

        await server?.stop()
        server = nil

        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()

        sessionTask?.cancel()

        for waiter in shutdownWaiters {
            waiter.resume()
        }
        shutdownWaiters.removeAll()
    }

    /// Starts every hook at once and waits for all of them under ONE shared
    /// deadline.
    ///
    /// Unbounded is not an option: a hook that never returns would hold
    /// shutdown open until core's SIGKILL lands, which is exactly the failure
    /// this SDK's shutdown design exists to avoid. Spec §5.3 names "flat sleep
    /// rather than drain-or-deadline" as a Go SDK gap; this is the deadline
    /// half.
    ///
    /// Concurrently rather than in registration order, which is the whole
    /// point of bounding: run them serially under a shared budget and one
    /// wedged hook eats the entire budget and starves every hook behind it —
    /// so a plugin's state flush gets silently skipped because some unrelated
    /// subsystem hung. (Measured: a 600 s hook registered first left the
    /// second hook unrun.) Hooks are independent registrations from
    /// independent subsystems and this SDK has never promised them an order,
    /// so parallel is both safe and the only shape that bounds each hook
    /// rather than the queue.
    ///
    /// A hook that overruns is cancelled, logged by index (it is a closure, it
    /// has no name), and abandoned — still running, but no longer waited on.
    private func drainShutdownHooks(_ hooks: [@Sendable () async -> Void]) async {
        guard !hooks.isEmpty else { return }

        let latches = hooks.map { _ in VCShutdownLatch() }
        let tasks = zip(hooks, latches).map { hook, latch in
            Task { await hook(); await latch.complete() }
        }

        let deadline = ContinuousClock.now + Self.shutdownHookBudget
        for (index, latch) in latches.enumerated() {
            // Never negative: a zero budget still reports a hook that already
            // finished as completed, and only flags one that has not.
            let remaining = max(.zero, deadline - ContinuousClock.now)
            if await latch.waitForCompletion(upTo: remaining) { continue }
            log("shutdown hook #\(index) overran the \(Self.shutdownHookBudget) drain budget; abandoning it")
            tasks[index].cancel()
        }
    }

    /// SIGTERM is the *only* guaranteed shutdown notice: `BroadcastShutdown`
    /// iterates live Register streams only, so a plugin that happens to be
    /// mid-reconnect never receives `CoreMsg.shutdown` at all.
    ///
    /// The handler does not exit. Core follows SIGTERM with SIGKILL after its
    /// 5 s grace period if the process is still alive, and a composition root
    /// awaiting `waitForShutdown()` ends long before that.
    private func trapTermination() {
        // The default disposition kills the process outright, so it has to be
        // ignored before a dispatch source can ever observe it.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.runShutdown() }
        }
        source.resume()
        signalSource = source
    }

    // MARK: - The session loop

    private func startSessionLoop() {
        guard sessionTask == nil else { return }
        sessionTask = Task { await self.runConnectionLoop() }
    }

    /// Outer loop: owns the gRPC client. Only ever re-entered if the client
    /// itself dies or wedges; ordinary Register drops are handled a level down
    /// so that `Publish`/`Alert` keep working across them.
    private func runConnectionLoop() async {
        while !stopped, !Task.isCancelled {
            do {
                let transport = try HTTP2ClientTransport.Posix(
                    target: .unixDomainSocket(path: socketPath),
                    transportSecurity: .plaintext
                )
                try await withGRPCClient(transport: transport) { grpc in
                    let client = VCKPluginHost.Client(wrapping: grpc)
                    self.client = client
                    defer { self.client = nil }
                    await self.runRegisterLadder(client)
                }
            } catch {
                // An unusable socket, a transport that gave up. Never fatal:
                // core may well hand us a working socket on its next start.
                log("gRPC client ended: \(error)")
            }
            guard !stopped, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(ladder.sessionEnded(lastedSeconds: 0)))
        }
    }

    /// Inner loop: owns the Register stream.
    ///
    /// The important shape here is that `thrown` is an `Error?` and the
    /// decision goes through `VCSessionOutcome.classify(error:)`. A session
    /// that ends *cleanly* — `rpc.go:146-149` returns `nil` when a
    /// non-superseded cancel closes the subscriber channel, which in
    /// grpc-swift is an `AsyncSequence` that simply finishes — leaves `thrown`
    /// nil and must reconnect exactly like a thrown error. A loop shaped
    /// `do { for try await … } catch { retry }` falls out of the `do` and
    /// never reconnects again, which is the single easiest way to write a
    /// plugin that looks alive and silently stops receiving events.
    private func runRegisterLadder<T: ClientTransport>(_ client: VCKPluginHost.Client<T>) async {
        var deadSessions = 0

        while !stopped, !Task.isCancelled {
            let startedAt = ContinuousClock.now
            sawReady = false

            var thrown: Error?
            do {
                try await runOneSession(client)
            } catch {
                thrown = error
            }
            guard !stopped, !Task.isCancelled else { return }

            switch VCSessionOutcome.classify(error: thrown) {
            case .stop:
                return
            case .reconnect:
                break
            }

            if let thrown {
                log("register session ended (\(thrown)); reconnecting")
            } else {
                log("register stream ended cleanly; reconnecting")
            }

            // A session that never reached Ready is evidence about the
            // connection, not about core's roster.
            deadSessions = sawReady ? 0 : deadSessions + 1
            if deadSessions >= Self.rebuildClientAfterDeadSessions {
                log("\(deadSessions) sessions without Ready; rebuilding the gRPC client")
                return
            }

            let lasted = ContinuousClock.now - startedAt
            let seconds = Double(lasted.components.seconds)
                + Double(lasted.components.attoseconds) / 1e18
            try? await Task.sleep(for: .seconds(ladder.sessionEnded(lastedSeconds: seconds)))
        }
    }

    /// One Register stream, raced against the ready watchdog. Returns
    /// normally only on a clean end of the response stream.
    private func runOneSession<T: ClientTransport>(_ client: VCKPluginHost.Client<T>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.consumeRegisterStream(client) }
            group.addTask { try await self.watchForReady() }

            // Whichever finishes first decides the session. `nextResult()`
            // rather than `next()` so the loser's cancellation error can be
            // drained explicitly instead of relying on the group's implicit
            // cleanup to swallow it.
            let first = await group.nextResult()
            group.cancelAll()
            while await group.nextResult() != nil {}
            if case .failure(let error) = first { throw error }
        }
    }

    private func consumeRegisterStream<T: ClientTransport>(
        _ client: VCKPluginHost.Client<T>
    ) async throws {
        var req = VCKRegisterReq()
        // Verbatim, always. Core reads `RegisterReq.id` and nothing else
        // (rpc.go:63-72) — it never cross-checks it against the call
        // metadata — so anything other than the spawn-time id silently
        // hijacks another plugin's proxy target and bus subscription.
        req.id = id
        req.httpPort = UInt32(httpPort)

        try await client.register(req, metadata: Self.attribution(id)) { response in
            if case .failure(let rejection) = response.accepted {
                throw Self.mapRegisterFailure(rejection)
            }
            do {
                for try await msg in response.messages {
                    switch msg.k {
                    case .ready:
                        await self.markReady()
                    case .event(let event):
                        await self.deliver(event)
                    case .shutdown(let shutdown):
                        self.log("core requested shutdown: \(shutdown.reason)")
                        await self.runShutdown()
                        throw VCHostError.shutdownRequested
                    case .none:
                        break
                    }
                }
            } catch let error as RPCError {
                throw Self.mapRegisterFailure(error)
            }
            // Falling out of the loop is a CLEAN end, not a success. The
            // caller turns it into `.reconnect`; see `runRegisterLadder`.
        }
    }

    /// Fails the session if core never acknowledges the registration, then
    /// parks until the session ends and cancels it.
    private func watchForReady() async throws {
        try await Task.sleep(for: Self.readyBudget)
        guard sawReady else { throw VCHostError.readyTimeout }
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    /// Note what is deliberately absent: `Ready` does NOT reset the reconnect
    /// ladder. `sessionEnded(lastedSeconds:)` already resets it for sessions
    /// that lasted `stableAfter`, so resetting here could only ever change
    /// behaviour for SHORT sessions — precisely the ones backoff exists to
    /// damp. A core that accepts, sends `Ready`, then drops the stream a
    /// couple of seconds later would otherwise pin the delay at the bottom
    /// rung forever: re-register, `Ready`, drop, sleep 1 s, repeat, one full
    /// registration and one `announceDemand` burst per second, indefinitely.
    /// It would also zero `deadSessions` on that same path and so disarm the
    /// client-rebuild valve below.
    private func markReady() {
        sawReady = true
        log("registered with core, serving on port \(httpPort)")
    }

    /// `NOT_FOUND` means core has no manifest with our id, so retrying cannot
    /// succeed until core is restarted with a corrected manifest. It is still
    /// not fatal: a plugin that exits here would be charged a failed start and
    /// would need a manual restart even after the manifest is fixed.
    private static func mapRegisterFailure(_ error: RPCError) -> any Error {
        error.code == .notFound
            ? VCHostError.registrationRejected(error.message)
            : error
    }

    /// Routed through `vcLog` rather than `FileHandle.standardError.write(_:)`,
    /// which aborts the process on a closed descriptor — see `VCLog.swift` for
    /// why that matters most in exactly this loop.
    private nonisolated func log(_ message: String) {
        vcLog("sdk: \(message)")
    }
}

/// A one-shot completion signal with a bounded wait.
///
/// This exists because a structured task group awaits every child before it
/// returns, so it cannot abandon work that ignores cancellation — which is
/// exactly the shutdown hook the drain budget exists to survive. The hook runs
/// in an unstructured `Task` and reports back through the latch instead.
actor VCShutdownLatch {
    private var completed = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Called by the work itself when it finishes.
    func complete() {
        completed = true
        release()
    }

    /// Returns `true` if the work completed within `budget`, `false` if the
    /// budget ran out first — in which case the work is still running and the
    /// caller has decided to stop waiting for it.
    func waitForCompletion(upTo budget: Duration) async -> Bool {
        guard !completed else { return true }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: budget)
            await self?.release()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Both branches run on this actor, so `release()` can never land
            // between the check and the store.
            if released {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
        timer.cancel()
        return completed
    }

    private func release() {
        guard !released else { return }
        released = true
        waiter?.resume()
        waiter = nil
    }
}
