import Foundation
import VCKStubs
@testable import VCGeometry

// Fixture builders shared by the suites in this target.
//
// Everything here is deliberately hand-computable: a fixture whose expected
// value can only be produced by running the implementation proves nothing, and
// design §2's third test ("it has a right answer, so a test can fail") is the
// only thing keeping the signals tier honest.

func vp(_ x: Float, _ y: Float) -> VCTPoint {
    var p = VCTPoint()
    p.x = x
    p.y = y
    return p
}

func vrect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> VCTRect {
    var r = VCTRect()
    r.x = x
    r.y = y
    r.w = w
    r.h = h
    return r
}

/// A header with a square frame, so `Aspect` is the identity unless a test
/// deliberately asks for a distorted one.
func vheader(width: UInt32 = 640, height: UInt32 = 640, seq: UInt64 = 7) -> VCTHeader {
    var size = VCTSize()
    size.w = width
    size.h = height
    var h = VCTHeader()
    h.seq = seq
    h.deviceID = "fixture-camera"
    h.frame = size
    return h
}

/// A header that never declared its frame size — what a synthetic or replayed
/// payload looks like.
func vheaderWithoutFrame(seq: UInt64 = 7) -> VCTHeader {
    var h = VCTHeader()
    h.seq = seq
    h.deviceID = "fixture-camera"
    return h
}

func vjoint(_ point: VCTPoint, confidence: Float) -> VCTJoint {
    var j = VCTJoint()
    j.point = point
    j.confidence = confidence
    return j
}

/// A body-pose frame with every one of the 19 joints present, parked far from
/// anything a test measures, so a test can overwrite just the joints it cares
/// about.
func vbody(_ overrides: [BodyJoint: (VCTPoint, Float)]) -> VCTBodyPoseFrame {
    var frame = VCTBodyPoseFrame()
    frame.header = vheader()
    frame.joints = BodyJoint.allCases.map { joint in
        if let (point, confidence) = overrides[joint] {
            return vjoint(point, confidence: confidence)
        }
        return vjoint(vp(0.9, 0.9), confidence: 0)
    }
    return frame
}

/// A hand with all 21 joints. `fingertips` overrides the five tip joints; the
/// rest are parked in a corner.
func vhand(fingertips: [HandJoint: VCTPoint],
           confidence: Float = 0.9,
           jointConfidence: [HandJoint: Float] = [:]) -> VCTHand {
    var hand = VCTHand()
    hand.confidence = confidence
    hand.handedness = .right
    hand.joints = HandJoint.allCases.map { fingertips[$0] ?? vp(0.05, 0.95) }
    if !jointConfidence.isEmpty {
        hand.jointConfidence = HandJoint.allCases.map { jointConfidence[$0] ?? confidence }
    }
    return hand
}

func vhands(_ hands: [VCTHand]) -> VCTHandsFrame {
    var frame = VCTHandsFrame()
    frame.header = vheader()
    frame.hands = hands
    return frame
}

// MARK: - Face fixtures

/// A fixed constellation used by every face fixture in this target.
///
/// The counts are ARBITRARY — they are one plausible shape, not a claim about
/// Apple's 65- or 76-point constellations, which is exactly why
/// `FaceLandmarkLayout` takes them as data instead of hard-coding them. What
/// the tests pin is that the layout and the geometry agree, whatever the
/// counts happen to be.
enum FaceFixture {
    static let eyeContourPoints = 6

    static let layout: FaceLandmarkLayout = FaceLandmarkLayout(pointCounts: [
        .faceContour: 11,
        .leftEye: eyeContourPoints,
        .rightEye: eyeContourPoints,
        .leftEyebrow: 6,
        .rightEyebrow: 6,
        .nose: 7,
        .noseCrest: 5,
        .medianLine: 5,
        .outerLips: 14,
        .innerLips: 6,
        .leftPupil: 1,
        .rightPupil: 1,
    ])!

    /// A six-point lens around `centre`, `halfWidth` wide and `halfHeight` tall
    /// in FRAME-HEIGHT units, optionally rotated. Its eye aspect ratio is
    /// exactly `halfHeight / halfWidth`: the corner-to-corner width is
    /// `2 * halfWidth` and the perpendicular extent is `2 * halfHeight`.
    static func eyeContour(centre: VCTPoint,
                           halfWidth: Float,
                           halfHeight: Float,
                           rollDegrees: Float = 0,
                           aspect: Aspect = .square) -> [VCTPoint] {
        let offsets: [Vector2] = [
            Vector2(x: -halfWidth, y: 0),
            Vector2(x: -halfWidth / 2, y: -halfHeight),
            Vector2(x: halfWidth / 2, y: -halfHeight),
            Vector2(x: halfWidth, y: 0),
            Vector2(x: halfWidth / 2, y: halfHeight),
            Vector2(x: -halfWidth / 2, y: halfHeight),
        ]
        let c = cos(Geometry.radians(rollDegrees))
        let s = sin(Geometry.radians(rollDegrees))
        return offsets.map { o in
            let rotated = Vector2(x: o.x * c - o.y * s, y: o.x * s + o.y * c)
            return denormalize(rotated, from: centre, aspect: aspect)
        }
    }

    /// Turns an offset in frame-height units into a normalized viewer-space
    /// point, undoing exactly what `Aspect` does. A fixture built this way
    /// keeps its physical shape when the frame's aspect ratio changes, which
    /// is what the aspect-invariance assertions rely on.
    static func denormalize(_ offset: Vector2, from origin: VCTPoint, aspect: Aspect) -> VCTPoint {
        vp(origin.x + offset.x / aspect.xScale, origin.y + offset.y)
    }

    /// Assembles a face frame from the four points the geometry actually reads,
    /// plus explicit eye contours for the eye aspect ratio. Every other region
    /// is filled with junk parked away from the face, so a bug that indexes the
    /// wrong region produces a wildly wrong number rather than a near-miss.
    static func frame(leftEyeContour: [VCTPoint],
                      rightEyeContour: [VCTPoint],
                      leftPupil: VCTPoint,
                      rightPupil: VCTPoint,
                      nose: VCTPoint,
                      mouth: VCTPoint,
                      bounds: VCTRect = vrect(0.3, 0.2, 0.4, 0.5),
                      confidence: Float = 0.92,
                      header: VCTHeader = vheader()) -> VCTFaceFrame {
        precondition(leftEyeContour.count == eyeContourPoints)
        precondition(rightEyeContour.count == eyeContourPoints)
        let junk = vp(0.99, 0.01)
        var points: [VCTPoint] = []
        for region in FaceRegion.allCases {
            let count = layout.pointCount(of: region)
            switch region {
            case .leftEye:     points += leftEyeContour
            case .rightEye:    points += rightEyeContour
            case .leftPupil:   points += [leftPupil]
            case .rightPupil:  points += [rightPupil]
            case .nose:        points += Array(repeating: nose, count: count)
            case .outerLips:   points += Array(repeating: mouth, count: count)
            default:           points += Array(repeating: junk, count: count)
            }
        }
        var frame = VCTFaceFrame()
        frame.header = header
        frame.bounds = bounds
        frame.points = points
        frame.confidence = confidence
        return frame
    }
}

// MARK: - Synthetic head

/// Projects a rigid head at a known attitude, using the very same weak
/// perspective `HeadPoseEstimator` inverts.
///
/// Sharing the forward model with the estimator would be circular if the
/// estimator simply ran it backwards — it does not. The estimator has no
/// knowledge of `yaw`, `pitch` or `roll` beyond four projected 2D points, and
/// recovering all three from those points exercises the de-roll, the
/// pitch-before-yaw ordering and both sign conventions. A sign error, a swapped
/// axis or the classic yaw/pitch coupling all show up here as a wrong angle.
struct SyntheticHead {
    /// Eye midpoint in normalized viewer-space coordinates.
    var eyeMidpoint: VCTPoint = vp(0.5, 0.40)
    /// Inter-ocular distance in FRAME-HEIGHT units.
    var interocular: Float = 0.16
    var model: HeadPoseModel = .default
    var aspect: Aspect = .square

    struct Projection {
        var leftEye: VCTPoint
        var rightEye: VCTPoint
        var nose: VCTPoint
        var mouth: VCTPoint
    }

    func project(yaw: Float, pitch: Float, roll: Float) -> Projection {
        let ty = Geometry.radians(yaw)
        let tp = Geometry.radians(pitch)
        let tr = Geometry.radians(roll)

        // Image axes: +x viewer's right, +y DOWN, +z into the screen. The head
        // starts facing the camera: right vector along +x, down along +y,
        // forward along -z.
        func pitched(_ v: SIMD3<Float>) -> SIMD3<Float> {
            // Positive pitch = looking up: down tips toward the camera.
            SIMD3(v.x, v.y * cos(tp) + v.z * sin(tp), -v.y * sin(tp) + v.z * cos(tp))
        }
        func yawed(_ v: SIMD3<Float>) -> SIMD3<Float> {
            // Positive yaw = turned toward the subject's own right (+x).
            SIMD3(v.x * cos(ty) - v.z * sin(ty), v.y, v.x * sin(ty) + v.z * cos(ty))
        }
        func rolled(_ v: SIMD3<Float>) -> SIMD3<Float> {
            // Positive roll = right eye lower on screen.
            SIMD3(v.x * cos(tr) - v.y * sin(tr), v.x * sin(tr) + v.y * cos(tr), v.z)
        }
        func transform(_ v: SIMD3<Float>) -> SIMD3<Float> { rolled(yawed(pitched(v))) }

        let right = transform(SIMD3(1, 0, 0))
        let down = transform(SIMD3(0, 1, 0))
        let forward = transform(SIMD3(0, 0, -1))

        func place(_ v: SIMD3<Float>) -> VCTPoint {
            FaceFixture.denormalize(Vector2(x: v.x * interocular, y: v.y * interocular),
                                    from: eyeMidpoint,
                                    aspect: aspect)
        }

        return Projection(leftEye: place(right * -0.5),
                          rightEye: place(right * 0.5),
                          nose: place(down * model.noseDrop + forward * model.noseProjection),
                          mouth: place(down * model.mouthDrop))
    }

    /// The same head, dressed up as a full face frame: pupils at the eye
    /// centres, the nose and lip regions collapsed onto their single points,
    /// and eye contours of the requested openness drawn around each pupil.
    func faceFrame(yaw: Float,
                   pitch: Float,
                   roll: Float,
                   eyeAspectRatio: Float = 0.35,
                   header: VCTHeader = vheader()) -> VCTFaceFrame {
        let projection = project(yaw: yaw, pitch: pitch, roll: roll)
        let halfWidth = interocular * 0.18
        let halfHeight = halfWidth * eyeAspectRatio
        return FaceFixture.frame(
            leftEyeContour: FaceFixture.eyeContour(centre: projection.leftEye,
                                                   halfWidth: halfWidth,
                                                   halfHeight: halfHeight,
                                                   rollDegrees: roll,
                                                   aspect: aspect),
            rightEyeContour: FaceFixture.eyeContour(centre: projection.rightEye,
                                                    halfWidth: halfWidth,
                                                    halfHeight: halfHeight,
                                                    rollDegrees: roll,
                                                    aspect: aspect),
            leftPupil: projection.leftEye,
            rightPupil: projection.rightEye,
            nose: projection.nose,
            mouth: projection.mouth,
            header: header)
    }
}

// MARK: - Assertions

/// Absolute tolerance for a quantity in frame-height units. Float32 through a
/// handful of trig calls loses a few ulps; 1e-5 of a frame height is far below
/// anything a camera can resolve.
let lengthTolerance: Float = 1e-5
/// Absolute tolerance in degrees, same reasoning.
let angleTolerance: Float = 1e-3

func isClose(_ a: Float, _ b: Float, tolerance: Float) -> Bool {
    abs(a - b) <= tolerance
}
