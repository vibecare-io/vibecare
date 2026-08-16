import Foundation
import VCKStubs

/// The face-landmark regions Vision concatenates into `FaceFrame.points`, in
/// the order the proto declares them.
///
/// The ORDER is normative — `proto/topics/v1/vision.proto` pins it, and this
/// enum's `allCases` is that order. The per-region point COUNTS deliberately
/// are not: they are a property of Apple's constellation and they differ
/// between the 65- and 76-point ones, so hard-coding them here would bake a
/// number nobody in this repo can verify into every signal. Counts arrive at
/// runtime instead, as a `FaceLandmarkLayout` built from the regions Vision
/// actually returned.
///
/// "left" and "right" are the SUBJECT's left and right. In viewer space —
/// a mirrored selfie preview — the subject's left appears on the viewer's left,
/// so `leftEye` sits at the SMALLER x. That is the opposite of what a naive
/// read of an unmirrored image would give, and it is why the mirroring happens
/// once at the edge (`ViewerSpace`) instead of being argued about here.
public enum FaceRegion: Int, CaseIterable, Sendable {
    case faceContour = 0
    case leftEye
    case rightEye
    case leftEyebrow
    case rightEyebrow
    case nose
    case noseCrest
    case medianLine
    case outerLips
    case innerLips
    case leftPupil
    case rightPupil
}

/// Where each region starts inside a `FaceFrame.points` array.
///
/// Built by whoever ran `VNDetectFaceLandmarksRequest`, from the `pointCount`
/// of each region it published, and handed to `VCGeometry` alongside the frame.
/// This is the seam that lets the geometry be pure: it never imports Vision,
/// never guesses a constellation, and fails loudly (`nil`) when the layout and
/// the points disagree instead of reading a neighbouring region's coordinates
/// and calling them an eye.
public struct FaceLandmarkLayout: Sendable, Equatable {
    /// Point count per region, indexed by `FaceRegion.rawValue`.
    public let pointCounts: [Int]
    /// Start index per region, indexed by `FaceRegion.rawValue`.
    private let offsets: [Int]
    /// Total points a conforming `FaceFrame.points` must contain.
    public let totalPointCount: Int

    /// - Parameter counts: one entry per `FaceRegion`, in `allCases` order.
    ///   A region Vision did not return (pupils are routinely absent) takes 0
    ///   and simply has an empty range; that is not an error.
    /// - Returns: `nil` when the array is the wrong length or holds a negative
    ///   count — both mean the caller built the layout from something other
    ///   than the regions it published.
    public init?(pointCounts counts: [Int]) {
        guard counts.count == FaceRegion.allCases.count else { return nil }
        guard counts.allSatisfy({ $0 >= 0 }) else { return nil }
        var running = 0
        var starts: [Int] = []
        starts.reserveCapacity(counts.count)
        for c in counts {
            starts.append(running)
            running += c
        }
        self.pointCounts = counts
        self.offsets = starts
        self.totalPointCount = running
    }

    /// Convenience for callers that have a dictionary keyed by region; a
    /// missing key means that region contributed no points.
    public init?(pointCounts map: [FaceRegion: Int]) {
        self.init(pointCounts: FaceRegion.allCases.map { map[$0] ?? 0 })
    }

    public func range(of region: FaceRegion) -> Range<Int> {
        let start = offsets[region.rawValue]
        return start ..< (start + pointCounts[region.rawValue])
    }

    public func pointCount(of region: FaceRegion) -> Int {
        pointCounts[region.rawValue]
    }
}

/// A validated read-only view over one published `FaceFrame`.
///
/// Constructing one is the whole "check `points.size()` first" discipline the
/// proto asks of face-frame consumers, done once: after this succeeds, every
/// region slice is in bounds by construction.
///
/// An EMPTY frame — no points — is a valid published message meaning "the model
/// ran and saw no face", and it yields `nil` here. That is not the same as no
/// message at all (the model is not running), and the two must not be collapsed:
/// the first says the user is away, the second says the camera is off. Both end
/// up leaving the face-derived signals absent, which is correct, because absent
/// means "unknown" in both cases and never zero.
public struct FaceLandmarks: Sendable {
    public let points: [VCTPoint]
    public let layout: FaceLandmarkLayout
    /// The published bounding box. Carried for context only — **no signal in
    /// this module reads it**, so a detector that reports a zero-area box
    /// cannot poison eye aspect ratio or head pose. `FaceLandmarksTests` pins
    /// that independence.
    public let bounds: VCTRect
    public let confidence: Float

    public init?(points: [VCTPoint],
                 layout: FaceLandmarkLayout,
                 bounds: VCTRect = VCTRect(),
                 confidence: Float = 0) {
        guard layout.totalPointCount > 0, points.count == layout.totalPointCount else { return nil }
        self.points = points
        self.layout = layout
        self.bounds = bounds
        self.confidence = confidence
    }

    public init?(frame: VCTFaceFrame, layout: FaceLandmarkLayout) {
        self.init(points: frame.points,
                  layout: layout,
                  bounds: frame.bounds,
                  confidence: frame.confidence)
    }

    public func points(of region: FaceRegion) -> ArraySlice<VCTPoint> {
        points[layout.range(of: region)]
    }

    /// Arithmetic mean of a region's points, in normalized viewer space.
    /// `nil` for a region Vision did not return.
    public func centroid(of region: FaceRegion) -> VCTPoint? {
        Self.centroid(of: points(of: region))
    }

    /// The best available centre for one eye: the pupil when the constellation
    /// carried one (a single point, and steadier than a contour mean under
    /// partial closure), otherwise the eye contour's centroid.
    public func eyeCentre(_ side: FaceSide) -> VCTPoint? {
        switch side {
        case .left:  return centroid(of: .leftPupil) ?? centroid(of: .leftEye)
        case .right: return centroid(of: .rightPupil) ?? centroid(of: .rightEye)
        }
    }

    /// Where the nose is, as a single point. The centroid of the `nose` region
    /// rather than a "tip" index: the region is present in every constellation
    /// and its mean is stable, whereas which index is the tip is exactly the
    /// per-constellation detail this module refuses to hard-code. `HeadPoseModel`
    /// is calibrated against this choice, so changing it means recalibrating.
    public var nose: VCTPoint? { centroid(of: .nose) }

    /// Where the mouth is, as a single point: the centroid of the outer lips.
    public var mouth: VCTPoint? { centroid(of: .outerLips) }

    static func centroid(of points: some Collection<VCTPoint>) -> VCTPoint? {
        guard !points.isEmpty else { return nil }
        var sx: Float = 0
        var sy: Float = 0
        for p in points {
            sx += p.x
            sy += p.y
        }
        let n = Float(points.count)
        var out = VCTPoint()
        out.x = sx / n
        out.y = sy / n
        return out
    }
}

/// Which side of the SUBJECT's body a paired landmark belongs to — never which
/// side of the image it appears on.
public enum FaceSide: Sendable, CaseIterable {
    case left
    case right
}
