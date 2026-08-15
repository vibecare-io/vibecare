import CoreGraphics
import Foundation

public enum BFRBBehavior: String, CaseIterable, Sendable, Identifiable {
    case nailBiting, nosePicking, hairPulling
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .nailBiting:  return "Nail-biting"
        case .nosePicking: return "Nose-picking"
        case .hairPulling: return "Hair-pulling"
        }
    }

    // MARK: - Detection-notification presentation
    //
    // The icon/copy shown by the VibeNotify alert on a confirmed detection
    // (see VibeNotifyConfig.showBFRBAlert). Kept here as the single source of
    // truth so the visuals and the behavior model never drift apart.

    /// SF Symbol shown as the notification's icon.
    public var alertIcon: String {
        switch self {
        case .nailBiting:  return "hand.raised.fill"
        case .nosePicking: return "nose.fill"
        case .hairPulling: return "comb.fill"
        }
    }

    /// Warm, encouraging redirection used as the notification message.
    public var nudge: String {
        switch self {
        case .nailBiting:  return "Take a breath — hands down 💛"
        case .nosePicking: return "Ease off — hands away 💛"
        case .hairPulling: return "Gently — hands down 💛"
        }
    }

    /// Bundled icon id used as this behavior's default alert icon
    /// (matches the backend catalog id and the /api/icons/<id>.svg path).
    public var defaultIconId: String {
        switch self {
        case .nailBiting:  return "nail-biting"
        case .nosePicking: return "nose-picking"
        case .hairPulling: return "hair-pulling"
        }
    }
}

/// Converts Vision's normalized coordinates (origin bottom-left, y UP) into
/// viewer space (origin top-left, y DOWN) — the frame as the user sees
/// themselves in a mirrored selfie preview, per architecture v2 §10.1.
///
/// y is always flipped (Vision is y-up). x is flipped ONLY when `mirrored`
/// is false. This used to be documented as "x is deliberately untouched
/// because the front camera is already mirrored by the OS" — that premise
/// was measured false: with `automaticallyAdjustsVideoMirroring` left at
/// its default, BOTH a data-output connection's and a preview layer's
/// `isVideoMirrored` came back `false` for the built-in camera on real
/// hardware (see `CameraSession.configure()`'s comment for the measurement,
/// and the Task 11/12 report for the raw run). macOS is not silently doing
/// the mirroring for this plugin, so the plugin does it itself, driven by
/// the per-frame flag it actually measured — never by which camera it
/// thinks it has.
///
/// This is the single canonical conversion. `VisionLandmarkExtractor` calls
/// it for every point/rect it emits, and per the architecture ruling that
/// followed this measurement, whatever encodes the preview JPEG (Task 14)
/// must derive its own flip from the same `mirrored` value carried on
/// `LandmarkFrame.mirrored` — not reimplement this rule, and not read
/// mirroring state from anywhere else.
public enum ViewerSpace {
    public static func point(_ p: CGPoint, mirrored: Bool) -> CGPoint {
        let x = mirrored ? p.x : 1 - p.x
        return CGPoint(x: x, y: 1 - p.y)
    }

    /// A Vision rect's TOP edge is at y-up `maxY`, which becomes viewer
    /// `1 - maxY`. When not mirrored, the rect's right edge (`maxX`) becomes
    /// the new left edge, so the new `minX` is `1 - maxX` — the same rule
    /// `point` applies to x, so `rect(_:mirrored:).midX` always equals
    /// `point(_:mirrored:)` applied to the original rect's midpoint (see
    /// `GeometryTests` for the assertion pinning that agreement). Width and
    /// height are unchanged either way.
    public static func rect(_ r: CGRect, mirrored: Bool) -> CGRect {
        let minX = mirrored ? r.minX : 1 - r.maxX
        return CGRect(x: minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}

/// All points are normalized [0,1] in VIEWER space: origin top-left,
/// x increases right, y increases DOWN. Consumers never re-convert.
public struct HandGeometry: Sendable {
    public var fingertips: [CGPoint]

    public init(fingertips: [CGPoint]) {
        self.fingertips = fingertips
    }
}
public struct FaceGeometry: Sendable {
    public var box: CGRect
    public var nose: CGPoint
    public var mouth: CGPoint

    public init(box: CGRect, nose: CGPoint, mouth: CGPoint) {
        self.box = box
        self.nose = nose
        self.mouth = mouth
    }
}

/// Coarse boolean grid of the person-segmentation mask, row-major,
/// row 0 = TOP. In viewer space y=0 is the top, so the row index is a
/// direct scale of y with no flip.
public struct HairMask: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    public let cells: [Bool]

    public init(cols: Int, rows: Int, cells: [Bool]) {
        self.cols = cols
        self.rows = rows
        self.cells = cells
    }

    public func isPerson(atNormalized p: CGPoint) -> Bool {
        guard cols > 0, rows > 0, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return false }
        let col = min(cols - 1, max(0, Int(p.x * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int(p.y * CGFloat(rows))))
        return cells[row * cols + col]
    }
}

public struct LandmarkFrame: Sendable {
    public var hand: HandGeometry?
    public var face: FaceGeometry?
    /// Pixel-buffer dimensions the landmarks were computed against, used by
    /// the overlay to map normalized points through the aspect-fill crop.
    public var imageSize: CGSize = .zero
    /// Coarse person-segmentation grid used to draw a head/hair-shaped
    /// overlay and to sample hair-pulling detection consistently with it.
    /// nil when segmentation is unavailable (falls back to the geometric
    /// hair zone).
    public var hairMask: HairMask?
    /// Capture time, not analysis time. Sampling at analysis time folds
    /// inference latency into the timestamp, which step 6's ±250ms
    /// conformance budget cannot absorb.
    public var ts: Date = Date()
    /// Monotonic per provider. Gaps mean dropped frames — the 15fps throttle
    /// discards frames and today there is no record of it.
    public var seq: UInt64 = 0
    /// Whether the SOURCE connection reported itself as already mirrored
    /// (`AVCaptureConnection.isVideoMirrored`, read per frame — see
    /// `CameraSession.captureOutput`). NOT diagnostics-only: coordinates on
    /// this struct have already been flipped through `ViewerSpace` using
    /// this exact value, and it is the single source of truth both that
    /// landmark flip and Task 14's JPEG preview flip must derive from. The
    /// two surfaces disagreeing about which flip to apply is exactly the
    /// bug this field exists to prevent.
    public var mirrored: Bool = true

    public init(hand: HandGeometry? = nil,
                face: FaceGeometry? = nil,
                imageSize: CGSize = .zero,
                hairMask: HairMask? = nil,
                ts: Date = Date(),
                seq: UInt64 = 0,
                mirrored: Bool = true) {
        self.hand = hand
        self.face = face
        self.imageSize = imageSize
        self.hairMask = hairMask
        self.ts = ts
        self.seq = seq
        self.mirrored = mirrored
    }
}
