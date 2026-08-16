import CoreGraphics
import Foundation
import VCKStubs

/// The `vision.*` topics this plugin consumes, as declared in
/// `manifest.yaml`'s `subscribes`. The raw values ARE the wire topic names —
/// a typo here is a subscription that silently never fires, so they are
/// written once and never re-spelled at a call site.
public enum VisionTopic: String, CaseIterable, Sendable, Codable {
    case face = "vision.face.v1"
    case hands = "vision.hands.v1"
    case segmentation = "vision.segmentation.v1"
}

// MARK: - Face anchors

/// The two points and one box `BFRBDetector` measures against, in viewer
/// space (origin top-left, y DOWN, normalized 0..1 — `Point`'s convention in
/// `proto/topics/v1/vision.proto`, applied by the provider before publishing).
///
/// This replaces the deleted `FaceGeometry`. It is deliberately still a
/// three-value struct rather than the raw 76-point cloud: the detector's
/// whole geometry is "is a fingertip near the nose / the mouth / above the
/// forehead", and reducing once, here, keeps that arithmetic identical to
/// what shipped before the cutover.
public struct FaceAnchors: Sendable, Equatable {
    /// How `nose`/`mouth` were obtained. Reported so the degraded path is
    /// visible rather than silent — see `FaceAnchors.from(_:)`.
    public enum Source: String, Sendable, Equatable {
        /// Indexed out of `FaceFrame.points` using a known constellation
        /// layout, and the result passed the plausibility check.
        case landmarks
        /// Derived from `FaceFrame.bounds` alone, because the point cloud
        /// was absent, was a length no known layout describes, or produced
        /// anchors that could not be a real nose and mouth.
        case bounds
    }

    public let box: CGRect
    public let nose: CGPoint
    public let mouth: CGPoint
    public let source: Source

    public init(box: CGRect, nose: CGPoint, mouth: CGPoint, source: Source = .landmarks) {
        self.box = box
        self.nose = nose
        self.mouth = mouth
        self.source = source
    }

    /// Reduces a published `FaceFrame` to the anchors the detector needs, or
    /// `nil` for the "no face detected" message (an empty frame with a zero
    /// `bounds`, which §4 is explicit is a VALID publication and not an
    /// error).
    ///
    /// ## Why this is not a plain array index
    ///
    /// `FaceFrame.points` is Apple's `allPoints` constellation, regions
    /// concatenated in Vision's own order. The proto deliberately does NOT
    /// pin the per-region point counts — they differ between the 65- and
    /// 76-point constellations, and pinning a number nobody had measured
    /// would have been a fiction on the wire. So a consumer indexing a
    /// region has to state the layout it believes it is receiving, check the
    /// belief, and have somewhere to go when the check fails. All three
    /// happen here.
    ///
    /// A wrong offset table is the dangerous failure: it does not crash, it
    /// silently reports an eyebrow as the nose and the detector fires on the
    /// wrong part of the face. `plausible(_:_:in:)` below is what makes that
    /// loud instead — a nose has to be near the middle of the face box both
    /// horizontally and vertically, and above the mouth. Eyes, eyebrows and
    /// contour points all fail it.
    public static func from(_ frame: VCTFaceFrame) -> FaceAnchors? {
        let box = viewerRect(frame.bounds)
        guard box.width > 0, box.height > 0 else { return nil }

        if let layout = FaceLandmarkLayout.fromWire(frame),
           let nose = centroid(of: frame.points, in: layout.nose),
           let mouth = centroid(of: frame.points, in: layout.outerLips),
           plausible(nose: nose, mouth: mouth, in: box) {
            return FaceAnchors(box: box, nose: nose, mouth: mouth, source: .landmarks)
        }

        // Same fallback the pre-cutover `VisionLandmarkExtractor.extractFace`
        // used whenever `landmarks?.nose` / `landmarks?.outerLips` came back
        // nil: the face box's own centre for the nose, and a fifth of the box
        // height up from its bottom edge for the mouth. Converted to viewer
        // space, "a fifth up from the bottom" is `maxY - 0.2 * height`.
        return FaceAnchors(
            box: box,
            nose: CGPoint(x: box.midX, y: box.midY),
            mouth: CGPoint(x: box.midX, y: box.maxY - box.height * 0.2),
            source: .bounds
        )
    }

    /// A nose and a mouth have to sit near the vertical midline of the face
    /// box, in the lower-middle and lower thirds respectively, with the nose
    /// above the mouth. Every other region in the constellation — contour,
    /// eyes, eyebrows, pupils — violates at least one of those, which is
    /// what lets a mis-indexed layout be caught here instead of shipping as
    /// a detector that fires on foreheads.
    ///
    /// The bands are deliberately generous: this is a wrong-region check,
    /// not a calibration. A real nose centroid sits around 0.55 of the box
    /// height and a real outer-lips centroid around 0.75.
    static func plausible(nose: CGPoint, mouth: CGPoint, in box: CGRect) -> Bool {
        guard nose.y < mouth.y else { return false }
        func within(_ p: CGPoint, dx: CGFloat, yRange: ClosedRange<CGFloat>) -> Bool {
            guard abs(p.x - box.midX) <= dx * box.width else { return false }
            let t = (p.y - box.minY) / box.height
            return yRange.contains(t)
        }
        return within(nose, dx: 0.25, yRange: 0.30...0.80)
            && within(mouth, dx: 0.30, yRange: 0.55...1.05)
    }

    private static func centroid(of points: [VCTPoint], in range: Range<Int>) -> CGPoint? {
        guard range.lowerBound >= 0, range.upperBound <= points.count, !range.isEmpty else { return nil }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for i in range {
            sx += CGFloat(points[i].x)
            sy += CGFloat(points[i].y)
        }
        let n = CGFloat(range.count)
        return CGPoint(x: sx / n, y: sy / n)
    }

    /// `Rect` is already viewer space (`x`,`y` is the TOP-LEFT corner), so
    /// this is a straight widening from `Float` to `CGFloat` and nothing
    /// else. It exists as a named function anyway, because "the provider
    /// already converted" is a claim worth having one place to point at:
    /// re-flipping y here is exactly the bug §4.3 exists to prevent, and a
    /// bare `CGRect(x:y:w:h:)` at three call sites is where that creeps in.
    static func viewerRect(_ r: VCTRect) -> CGRect {
        CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h))
    }
}

/// Where each region starts and ends inside `FaceFrame.points`, for the
/// constellations this plugin knows how to read.
///
/// **This table is a belief about the provider, not a fact about the wire.**
/// `proto/topics/v1/vision.proto` states the region ORDER normatively and
/// explicitly declines to state the COUNTS, because they are a property of
/// Apple's model rather than of the contract. The provider pins the offsets
/// it actually publishes in its own tests; this is the consumer's mirror of
/// that, guarded by `FaceAnchors.plausible` so a disagreement degrades to
/// bounds-derived anchors instead of nonsense.
enum FaceLandmarkLayout {
    struct Layout {
        let nose: Range<Int>
        let outerLips: Range<Int>
    }

    /// Region order, per the proto:
    ///
    ///   faceContour · leftEye · rightEye · leftEyebrow · rightEyebrow ·
    ///   nose · noseCrest · medianLine · outerLips · innerLips ·
    ///   leftPupil · rightPupil
    ///
    /// The counts are NOT stated here. They arrive on the wire, in
    /// `FaceFrame.region_point_counts`.
    ///
    /// This plugin used to carry its own table for the 76-point
    /// constellation — 11, 8, 8, 6, 6, 9, 5, 5, 10, 6, 1, 1 — and index
    /// `allPoints` through it. Measured against a real camera on macOS 26 the
    /// regions are 17, 6, 6, 6, 6, 8, 6, 10, 14, 6, 1, 1: every offset after
    /// the face contour was wrong, and the "nose" centroid was being taken
    /// from somewhere in the eyes. It did not crash and it did not look
    /// broken; it produced a plausible point in the wrong place, which is why
    /// `plausible(nose:mouth:in:)` below exists and why a guessed table is
    /// never coming back.
    static let regionOrder = [
        "faceContour",
        "leftEye", "rightEye",
        "leftEyebrow", "rightEyebrow",
        "nose", "noseCrest", "medianLine",
        "outerLips", "innerLips",
        "leftPupil", "rightPupil",
    ]

    static func offsets(_ regions: [(name: String, count: Int)]) -> [String: Range<Int>] {
        var result: [String: Range<Int>] = [:]
        var cursor = 0
        for region in regions {
            result[region.name] = cursor..<(cursor + region.count)
            cursor += region.count
        }
        return result
    }

    /// Builds the layout from the counts the provider published alongside the
    /// points, refusing anything that does not describe exactly this array.
    ///
    /// Every rejection returns `nil`, which sends the caller to the bounding
    /// box — the honest degraded answer. Guessing a table would be the
    /// dishonest one, because a wrong table cannot be detected downstream.
    static func fromWire(_ frame: VCTFaceFrame) -> Layout? {
        let counts = frame.regionPointCounts.map(Int.init)
        // Empty means the provider could not determine its own layout. Any
        // other length means it is describing a different region list than
        // the one the contract pins.
        guard counts.count == regionOrder.count else { return nil }
        // The counts must describe THIS array, not merely be well formed.
        guard counts.reduce(0, +) == frame.points.count else { return nil }

        let o = offsets(zip(regionOrder, counts).map { (name: $0, count: $1) })
        guard let nose = o["nose"], let lips = o["outerLips"],
              !nose.isEmpty, !lips.isEmpty else { return nil }
        return Layout(nose: nose, outerLips: lips)
    }
}

// MARK: - Hands

public extension VCTHandsFrame {
    /// The five fingertip joints, in viewer space, from the highest-
    /// confidence hand.
    ///
    /// Indices 4/8/12/16/20 are the thumb/index/middle/ring/little tips —
    /// the proto declares that ordering NORMATIVE and guarantees the array
    /// is never short and never sparse, so these are constants rather than a
    /// search.
    ///
    /// `hands.first` and not all hands: `HandsFrame.hands` is ordered by
    /// descending confidence, and reading only the first preserves exactly
    /// what the pre-cutover `VisionLandmarkExtractor.extractHand` did
    /// (`handRequest.results?.first`, despite `maximumHandCount = 2`).
    /// Two-handed detection is listed as deliberately deferred in the design
    /// (§11); taking both hands here would double the fingertips fed to the
    /// detector and change how readily it fires, which is a behaviour change
    /// this cutover is not the place to make.
    var fingertips: [CGPoint] {
        guard let hand = hands.first else { return [] }
        let tipIndices = [4, 8, 12, 16, 20]
        // `joint_confidence` is either EMPTY (the provider does not report
        // it) or exactly as long as `joints`. Empty means UNKNOWN, not zero
        // — the proto is explicit that discarding the hand is the wrong
        // read — so the 0.3 gate the shipped detector applied per joint is
        // applied when the data is there and skipped when it is not.
        let confidences = hand.jointConfidence.count == hand.joints.count ? hand.jointConfidence : []
        var tips: [CGPoint] = []
        for i in tipIndices where i < hand.joints.count {
            if !confidences.isEmpty, confidences[i] <= 0.3 { continue }
            tips.append(CGPoint(x: CGFloat(hand.joints[i].x), y: CGFloat(hand.joints[i].y)))
        }
        return tips
    }
}

// MARK: - Segmentation

public extension VCTSegmentationFrame {
    /// Whether the person-segmentation mask marks the cell under `p` as
    /// person. Replaces the deleted `HairMask.isPerson(atNormalized:)`, with
    /// the identical clamping and out-of-range rules — the only difference
    /// is that the cells now arrive as a packed bitmask on the wire instead
    /// of a `[Bool]` in memory.
    ///
    /// Bit layout is the proto's: `index = row * w + col`, MSB first within
    /// each byte, row 0 = TOP (viewer space is y-down, so the row index is a
    /// direct scale of y with no flip).
    func isPerson(atNormalized p: CGPoint) -> Bool {
        let cols = Int(w), rows = Int(h)
        guard cols > 0, rows > 0, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return false }
        let col = min(cols - 1, max(0, Int(p.x * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int(p.y * CGFloat(rows))))
        let index = row * cols + col
        let byteOffset = index / 8
        guard byteOffset < mask.count else { return false }
        let byte = mask[mask.startIndex + byteOffset]
        return (byte >> (7 - UInt8(index % 8))) & 1 == 1
    }

    /// True when this frame carries an actual grid. `w == 0 && h == 0` with
    /// an empty mask is the valid "no person segmented" publication, which
    /// must be read as "no mask" — falling through to `BFRBDetector`'s
    /// geometric hair zone — and never as "the mask says no".
    var hasGrid: Bool { w > 0 && h > 0 && !mask.isEmpty }
}

// MARK: - The joined frame

/// One capture frame's worth of vision output, joined across topics by
/// `Header.seq` and reduced to what the detector reads.
///
/// Constructed only from a COMPLETE set (see `VisionFrameJoiner`): a frame
/// whose segmentation was dropped for a slow subscriber is skipped, never
/// evaluated against an earlier frame's hair data. The reduction happens
/// once here, in the initializer, rather than on every access — the detector
/// touches `fingertips` and `face` repeatedly inside its own loop, and
/// re-deriving a centroid per fingertip would be pure waste.
public struct VisionFrame: Sendable, Equatable {
    /// Shared by every topic derived from one capture frame; gaps mean
    /// dropped frames, never a protocol error.
    public let seq: UInt64
    /// Capture time as the provider reported it. Wall clock, and used only
    /// for diagnostics — `DetectionPolicy`'s dwell/cooldown arithmetic runs
    /// on this process's own `ContinuousClock`, because a duration measured
    /// against another process's wall clock can go backwards.
    public let ts: Date?
    public let fingertips: [CGPoint]
    public let face: FaceAnchors?
    /// `nil` when segmentation was not part of this join — either nobody
    /// asked for it (hair-pulling is off) or the provider published the
    /// empty "no person segmented" frame. Both mean the same thing to
    /// `BFRBDetector`: fall back to the geometric hair zone.
    public let segmentation: VCTSegmentationFrame?

    public init(face: VCTFaceFrame? = nil,
                hands: VCTHandsFrame? = nil,
                segmentation: VCTSegmentationFrame? = nil) {
        let header = face?.header ?? hands?.header ?? segmentation?.header
        self.seq = header?.seq ?? 0
        self.ts = (header?.hasTs ?? false) ? header?.ts.date : nil
        self.fingertips = hands?.fingertips ?? []
        self.face = face.flatMap(FaceAnchors.from)
        self.segmentation = (segmentation?.hasGrid ?? false) ? segmentation : nil
    }
}
