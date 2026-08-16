import Foundation

// The JSON `/api/*` actually emits.
//
// Designed first, HTML second: `/api/*` is the real interface and
// `ui/index.html` is merely its first consumer. A TUI, a script or a second
// client must be able to answer "is the camera on, and who turned it on"
// without parsing a page.
//
// `Codable` (not just `Encodable`) throughout so the plugin's own tests can
// decode what the handlers emit. Note that a round-trip through these types
// is a weak assertion — it agrees with itself by construction — which is why
// the tests that matter read the raw JSON keys instead.

// MARK: - /api/state

struct VisionStateDTO: Codable {
    /// The privacy sentence (`VisionSummary.line`). Served rather than
    /// assembled client-side so it is the same string everywhere and so a
    /// test can fail on it.
    var summary: String
    var camera: CameraDTO
    var devices: [DeviceDTO]
    /// Models actually running, in pipeline order. This is the readout §7
    /// draws: `face 30fps <- blink-jump, vibecheck`.
    var running: [ModelDTO]
    /// Everything vision *can* publish and currently does not. "hands is not
    /// running" is a privacy claim in its own right and disappears if only
    /// the running list is served.
    var idle: [ModelDTO]
    /// The live `vision.request.v1` union, so a consumer author can see
    /// whether their request actually landed.
    var requests: [RequestDTO]
    var warnings: [WarningDTO]

    init(_ state: VisionState, devices: [VisionCameraDevice], now: Date) {
        let sorted = VisionTopicCatalog.sorted(state.topics)
        summary = VisionSummary.line(camera: state.camera, topics: sorted)
        camera = CameraDTO(state.camera)
        self.devices = devices.map { DeviceDTO($0, selectedID: state.camera.selectedDeviceID) }
        running = sorted.filter(\.isRunning).map(ModelDTO.init)
        idle = sorted.filter { !$0.isRunning }.map(ModelDTO.init)
        requests = state.requests.map { RequestDTO($0, now: now) }
        warnings = VisionWarning.derive(from: sorted).map(WarningDTO.init)
    }

    struct CameraDTO: Codable {
        var open: Bool
        var permission: VisionCameraPermission
        var deviceId: String?
        var deviceName: String?
        /// `0` while closed — the overlay must not map anything until it has
        /// a real frame size, and zero is the honest way to say "not yet".
        var frameWidth: Int
        var frameHeight: Int
        var mirrored: Bool

        init(_ camera: VisionCameraState) {
            open = camera.isOpen
            permission = camera.permission
            deviceId = camera.selectedDeviceID
            deviceName = camera.selectedDeviceName
            frameWidth = camera.frameWidth
            frameHeight = camera.frameHeight
            mirrored = camera.isMirrored
        }
    }

    struct ModelDTO: Codable {
        var topic: String
        /// `vision.body_pose.v1` -> `body pose`. Served, not derived in the
        /// page, so every client says the same word for the same model.
        var model: String
        var fps: Int
        /// Sorted, so a readout does not reorder itself between polls just
        /// because two requests arrived in a different order.
        var requesters: [String]
        /// The kernel's demand refcount for this topic — process liveness,
        /// not user intent (§5.2). Present because `subscribers > 0` with
        /// `requesters == []` is precisely the wiring bug `warnings` names,
        /// and seeing both numbers is what makes that warning legible.
        var subscribers: Int

        init(_ status: VisionTopicStatus) {
            topic = status.topic
            model = VisionTopicCatalog.displayName(for: status.topic)
            fps = status.fps
            requesters = status.requesters.sorted()
            subscribers = status.subscribers
        }
    }

    struct DeviceDTO: Codable {
        var id: String
        var name: String
        var selected: Bool

        init(_ device: VisionCameraDevice, selectedID: String?) {
            id = device.id
            name = device.name
            selected = device.id == selectedID
        }
    }

    struct RequestDTO: Codable {
        var requester: String
        var topics: [String]
        var fps: Int
        /// Unix epoch seconds. `JSONEncoder`'s default `Date` strategy is
        /// seconds since 2001, which every non-Apple consumer of this API
        /// would read as a timestamp 31 years in the past.
        var expiresAt: Double
        /// Never negative: an already-lapsed request should not render as
        /// "expires in -4s" on its way out of the union.
        var expiresInSeconds: Int

        init(_ request: VisionActiveRequest, now: Date) {
            requester = request.requester
            topics = request.topics
            fps = request.fps
            expiresAt = request.expiresAt.timeIntervalSince1970
            expiresInSeconds = max(0, Int(request.expiresAt.timeIntervalSince(now).rounded()))
        }
    }

    struct WarningDTO: Codable {
        var code: VisionWarningCode
        var topic: String
        var subscribers: Int
        var message: String

        init(_ warning: VisionWarning) {
            code = warning.code
            topic = warning.topic
            subscribers = warning.subscribers
            message = warning.message
        }
    }
}

// MARK: - /api/devices, PUT /api/device

/// The response body of both `GET /api/devices` and a successful
/// `PUT /api/device` — the same shape from both, so the page can re-render
/// the picker from either without a second round trip.
struct VisionDevicesDTO: Codable {
    var devices: [VisionStateDTO.DeviceDTO]

    init(_ devices: [VisionCameraDevice], selectedID: String?) {
        self.devices = devices.map { VisionStateDTO.DeviceDTO($0, selectedID: selectedID) }
    }
}

struct VisionSelectDeviceRequest: Codable {
    var deviceId: String
}

// MARK: - /api/events

/// One overlay frame on the wire.
///
/// Coordinates are viewer space, already mirrored (§4.3) — the page applies
/// the aspect-fill transform and nothing else. Any flip here or there would
/// put the markers on the forehead instead of the nose, which is exactly the
/// bug the convention exists to prevent.
struct VisionOverlayFrameDTO: Codable {
    var seq: UInt64
    var ts: Double
    var imageWidth: Int
    var imageHeight: Int
    var face: FaceDTO?
    var hands: [HandDTO]
    var body: [JointDTO]
    var segmentation: MaskDTO?

    init(_ frame: VisionOverlayFrame) {
        seq = frame.seq
        ts = frame.ts.timeIntervalSince1970
        imageWidth = frame.imageWidth
        imageHeight = frame.imageHeight
        face = frame.face.map(FaceDTO.init)
        hands = frame.hands.map(HandDTO.init)
        body = frame.body.map(JointDTO.init)
        segmentation = frame.segmentation.map(MaskDTO.init)
    }

    struct PointDTO: Codable {
        var x: Double
        var y: Double

        init(_ point: VisionOverlayFrame.Point) {
            x = round4(point.x)
            y = round4(point.y)
        }
    }

    struct RectDTO: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: VisionOverlayFrame.Rect) {
            x = round4(rect.x)
            y = round4(rect.y)
            width = round4(rect.width)
            height = round4(rect.height)
        }
    }

    struct FaceDTO: Codable {
        var bounds: RectDTO
        var points: [PointDTO]
        var confidence: Double

        init(_ face: VisionOverlayFrame.Face) {
            bounds = RectDTO(face.bounds)
            points = face.points.map(PointDTO.init)
            confidence = round4(face.confidence)
        }
    }

    struct HandDTO: Codable {
        var chirality: String
        var points: [PointDTO]
        var confidence: Double

        init(_ hand: VisionOverlayFrame.Hand) {
            chirality = hand.chirality
            points = hand.points.map(PointDTO.init)
            confidence = round4(hand.confidence)
        }
    }

    struct JointDTO: Codable {
        var name: String
        var x: Double
        var y: Double
        var confidence: Double

        init(_ joint: VisionOverlayFrame.Joint) {
            name = joint.name
            x = round4(joint.point.x)
            y = round4(joint.point.y)
            confidence = round4(joint.confidence)
        }
    }

    /// Base64 of the packed bitmask, passed through byte for byte from
    /// `proto/topics/v1/vision.proto`'s `bytes mask`: row-major, MSB first,
    /// bit `i == row * cols + col` in byte `i / 8` at position `7 - (i % 8)`.
    ///
    /// Not re-packed here, deliberately. A 64x48 mask is 3072 cells; unpacking
    /// to `[Bool]` and re-packing would be pure work for the chance to
    /// disagree with the proto about bit order. `ui/index.html`'s decoder must
    /// agree with that packing, and it is the only thing that has to.
    struct MaskDTO: Codable {
        var cols: Int
        var rows: Int
        var bits: String

        init(_ mask: VisionOverlayFrame.Mask) {
            cols = mask.cols
            rows = mask.rows
            bits = Data(mask.packed).base64EncodedString()
        }
    }
}

/// Four decimal places on a 0..1 normalized coordinate is a quarter of a
/// pixel on a 4K display — below anything a preview overlay can show — and it
/// bounds the payload: a 76-point face at full `Float` precision serializes
/// roughly twice as long, every frame, for no visible difference.
private func round4(_ value: Float) -> Double {
    guard value.isFinite else { return 0 }
    return (Double(value) * 10_000).rounded() / 10_000
}
