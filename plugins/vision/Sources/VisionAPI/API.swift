import Foundation
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file.
/// `fputs`, never `FileHandle.standardError.write(_:)` — the `FileHandle`
/// overload raises an *uncatchable* `NSException` on a closed descriptor, and
/// core closes the plugin's stderr pipe during its own shutdown. Same rule,
/// same reason, as every other `fputs` comment in this repo's plugins.
private func apiLog(_ message: String) {
    fputs("vision: \(message)\n", stderr)
}

/// Vision's whole HTTP surface (§7).
///
/// `/api/*` is the real interface; the HTML at `/` is its first consumer.
/// That ordering is not a slogan here — `/api/state` is the privacy readout,
/// the one place in the product that says "the camera is on because postures
/// wants body pose", and it has to be answerable to a TUI, a script or a
/// second client with no change to core and no change here.
///
/// What this deliberately does NOT serve: any feature toggle. Vision has none
/// (§7). Models are derived from live demand and the `vision.request.v1`
/// union; a user turns a feature on in the plugin that owns the feature. A
/// `PUT /api/models` would be a fourth, silent control plane that the demand
/// floor could not gate — the exact thing §5 rejected.
///
/// `/health` is NOT registered here: `VCHost` installs it before it binds,
/// which is mandatory ordering (core's prober starts the instant the plugin
/// registers), and shadowing it from this function would replace the SDK's
/// `detail`-normalizing handler with one that does not know that core
/// force-clears `detail` on any transition to `up`.
///
/// Every dependency is passed in: this function wires already-built pieces to
/// paths and decides nothing about how they are built. The `loadUI` closure
/// in particular belongs to the composition root, which is the only place
/// that knows how this process was installed.
///
/// Error discipline, copied from `plugins/todo/main.go` and vibecheck's
/// `API.swift` because it encodes a real rule: a caller's mistake (malformed
/// JSON, an unknown device id) gets a 4xx carrying the message; anything else
/// gets logged server-side and answered with a generic 500, because a capture
/// error's text can name a device path that is not the client's to see.
public func registerVisionRoutes(
    router: VCRouter,
    state: any VisionStateSource,
    camera: any VisionCameraControl,
    preview: any VisionPreviewSink,
    overlay: any VisionOverlaySource,
    loadUI: @escaping @Sendable (String) -> Data? = VisionUI.load
) async {
    // MARK: GET / — the tab

    await router.handle("/") { request, writer in
        guard request.method == "GET" else {
            try await respondMethodNotAllowed(writer, "GET")
            return
        }
        guard let html = loadUI("ui/index.html") else {
            // Not fatal, and never `fatalError`/`exit`: a missing resource is
            // a 500 an operator can see. `supervisor.go` charges an
            // unrequested exit as a failed start, and five park the plugin in
            // StateFailed until a manual restart — over a missing HTML file.
            apiLog("ui/index.html is missing from the resource bundle")
            try await respondError(writer, status: 500, "UI resources are missing from this install")
            return
        }
        try await writer.writeHead(status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(html.count)",
            // The webview is long-lived and this page ships inside the
            // binary's resource bundle: a cached copy would survive a plugin
            // rebuild and quietly serve last week's UI against today's JSON.
            "Cache-Control": "no-store",
        ])
        try await writer.write(html)
        try await writer.finish()
    }

    // MARK: GET /api/state — the privacy readout

    await router.handle("/api/state") { request, writer in
        guard request.method == "GET" else {
            try await respondMethodNotAllowed(writer, "GET")
            return
        }
        // Two reads, one response. The device list comes from the camera
        // control rather than from the state snapshot so there is exactly one
        // enumeration path in the plugin — `/api/devices` and `/api/state`
        // can never disagree about which cameras exist.
        let snapshot = await state.visionState()
        let devices = await camera.availableCameras()
        try await respondJSON(writer, status: 200, VisionStateDTO(snapshot, devices: devices, now: Date()))
    }

    // MARK: GET /api/devices, PUT /api/device — camera selection

    await router.handle("/api/devices") { request, writer in
        guard request.method == "GET" else {
            try await respondMethodNotAllowed(writer, "GET")
            return
        }
        let devices = await camera.availableCameras()
        let selected = await state.visionState().camera.selectedDeviceID
        try await respondJSON(writer, status: 200, VisionDevicesDTO(devices, selectedID: selected))
    }

    // PUT, and only PUT. Unlike vibecheck's `/api/config/disable` and
    // `/api/snooze` — which are alert-action targets a client reaches by
    // following a URL, hence ruling P4's "GET must work too" — nothing ever
    // links to this. It is reached from the page's own picker, so the safe
    // method is the honest one.
    await router.handle("/api/device") { request, writer in
        guard request.method == "PUT" else {
            try await respondMethodNotAllowed(writer, "PUT")
            return
        }
        guard let decoded = try? JSONDecoder().decode(VisionSelectDeviceRequest.self, from: request.body),
              !decoded.deviceId.isEmpty else {
            try await respondError(writer, status: 400, "deviceId is required")
            return
        }
        switch await camera.selectCamera(id: decoded.deviceId) {
        case .selected:
            // Re-read rather than echo: a selection that landed on a device
            // that vanished mid-call must not be reported as current.
            let devices = await camera.availableCameras()
            let selected = await state.visionState().camera.selectedDeviceID
            try await respondJSON(writer, status: 200, VisionDevicesDTO(devices, selectedID: selected))

        case .unknownDevice:
            // The caller's mistake — a stale picker, or a camera unplugged
            // between the poll and the write — so it carries its message.
            try await respondError(writer, status: 404, "no camera with that id is attached")

        case .failed(let reason):
            apiLog("camera selection failed: \(reason)")
            try await respondError(writer, status: 500, "internal error")
        }
    }

    // MARK: GET /preview.mjpeg

    await router.handle("/preview.mjpeg") { request, writer in
        guard request.method == "GET" else {
            try await respondMethodNotAllowed(writer, "GET")
            return
        }
        // Attach-and-return, deliberately: the sink owns the writer from here
        // on and drives it from the camera's own frame callback, independent
        // of this request's `Task`. That is what lets several viewers share
        // one upstream camera — each `attach` would otherwise have to block
        // its own request `Task` forever, which cannot work for a fan-out fed
        // from outside the request.
        //
        // It is also what makes "encode only while a browser is attached"
        // (§6) expressible at all: the sink's writer registry IS the
        // attached-client count, so an empty registry is a cheap early return
        // on the capture path instead of a JPEG encoded for nobody.
        //
        // One consequence, same as vibecheck: this handler's `Task` completes
        // immediately, so a LATER pipelined request on this keep-alive
        // connection is not serialized behind this stream's writes. No
        // mainstream client pipelines; a known, accepted gap.
        await preview.attach(writer)
    }

    // MARK: GET /api/events — the overlay tiers

    await router.handle("/api/events") { request, writer in
        guard request.method == "GET" else {
            try await respondMethodNotAllowed(writer, "GET")
            return
        }
        try await writer.writeHead(status: 200, headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-store",
        ])
        // Unlike `/preview.mjpeg` this one blocks for the connection's
        // lifetime, because the provider hands out a stream per viewer rather
        // than holding writers: iterating it here means the stream (and with
        // it the provider's per-viewer bookkeeping, via `onTermination`) is
        // torn down the moment this handler returns.
        //
        // A failed `write` throws out of the loop, which is how a closed tab
        // is detected — there is no other signal. `VCHTTPHandler` logs it and
        // drops the connection, which is correct: bytes are already on the
        // wire, so no second status line is possible.
        let frames = await overlay.overlayFrames()
        for await frame in frames {
            try Task.checkCancellation()
            try await writer.write(sseMessage(event: "frame", dto: VisionOverlayFrameDTO(frame)))
        }
        try await writer.finish()
    }
}

// MARK: - SSE framing

private func sseMessage(event: String, dto: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []   // compact: no embedded newlines to break SSE framing
    let json = (try? encoder.encode(dto)) ?? Data(#"{}"#.utf8)
    var data = Data("event: \(event)\ndata: ".utf8)
    data.append(json)
    data.append(Data("\n\n".utf8))
    return data
}

// MARK: - Response helpers

private func respondJSON(_ writer: any VCResponseWriter, status: Int, _ value: some Encodable) async throws {
    let body = (try? JSONEncoder().encode(value)) ?? Data(#"{}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

private func respondError(_ writer: any VCResponseWriter, status: Int, _ message: String) async throws {
    let body = (try? JSONEncoder().encode(["error": message])) ?? Data(#"{"error":"unknown"}"#.utf8)
    try await writer.writeHead(status: status, headers: [
        "Content-Type": "application/json",
        "Content-Length": "\(body.count)",
    ])
    try await writer.write(body)
    try await writer.finish()
}

private func respondMethodNotAllowed(_ writer: any VCResponseWriter, _ allow: String) async throws {
    try await writer.writeHead(status: 405, headers: ["Allow": allow])
    try await writer.finish()
}
