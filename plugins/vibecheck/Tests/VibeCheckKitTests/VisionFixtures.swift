import CoreGraphics
import Foundation
import VCKStubs
@testable import VibeCheckKit

// Builders for the `vision.*` bus payloads this plugin consumes.
//
// Every detector/engine test below used to construct a `LandmarkFrame` — a
// type this plugin owned and could shape however the test found convenient.
// Post-cutover the input is the wire format, so the fixtures build real
// `VCTFaceFrame`/`VCTHandsFrame`/`VCTSegmentationFrame` values and let the
// production reduction (`FaceAnchors.from`, `HandsFrame.fingertips`,
// `SegmentationFrame.isPerson`) run on them. That is the point: a test that
// hand-built `FaceAnchors` directly would still pass if the proto adaptation
// were wrong in every particular.
//
// Not `private`: Swift's file-private access means test files cannot see
// each other's `private` helpers, and four suites need these.
enum Fixtures {

    static func point(_ p: CGPoint) -> VCTPoint {
        var v = VCTPoint()
        v.x = Float(p.x)
        v.y = Float(p.y)
        return v
    }

    static func header(seq: UInt64, ts: Date? = nil) -> VCTHeader {
        var h = VCTHeader()
        h.seq = seq
        h.deviceID = "test-camera"
        if let ts { h.ts = .init(date: ts) }
        var size = VCTSize()
        size.w = 1280
        size.h = 720
        h.frame = size
        return h
    }

    // MARK: - Faces

    /// A face frame carrying a full 76-point cloud whose `nose` region sits
    /// exactly on `nose` and whose `outerLips` region sits exactly on
    /// `mouth`, so `FaceAnchors.from` recovers both by centroid.
    ///
    /// Every other point is parked on the top edge of the box — somewhere a
    /// real contour/eyebrow point plausibly is, and nowhere that could be
    /// mistaken for the two anchors under test.
    static func face(seq: UInt64 = 1, box: CGRect, nose: CGPoint, mouth: CGPoint) -> VCTFaceFrame {
        var frame = VCTFaceFrame()
        frame.header = header(seq: seq)
        frame.bounds = rect(box)
        frame.confidence = 0.9

        let offsets = FaceLandmarkLayout.offsets(FaceLandmarkLayout.regions76)
        let total = FaceLandmarkLayout.regions76.reduce(0) { $0 + $1.count }
        var points = [VCTPoint](repeating: point(CGPoint(x: box.midX, y: box.minY)), count: total)
        for i in offsets["nose"]! { points[i] = point(nose) }
        for i in offsets["outerLips"]! { points[i] = point(mouth) }
        frame.points = points
        return frame
    }

    /// A face frame with a bounding box and NO landmark cloud — what a
    /// provider publishes for a constellation this plugin does not know, and
    /// the input that must drive `FaceAnchors.Source.bounds`.
    static func faceBoundsOnly(seq: UInt64 = 1, box: CGRect) -> VCTFaceFrame {
        var frame = VCTFaceFrame()
        frame.header = header(seq: seq)
        frame.bounds = rect(box)
        frame.confidence = 0.9
        return frame
    }

    /// The valid "no face detected" publication: a real message with a zero
    /// bounds and no points. Distinct from no message at all, which means
    /// the model is not running.
    static func noFace(seq: UInt64 = 1) -> VCTFaceFrame {
        var frame = VCTFaceFrame()
        frame.header = header(seq: seq)
        return frame
    }

    static func rect(_ r: CGRect) -> VCTRect {
        var v = VCTRect()
        v.x = Float(r.minX)
        v.y = Float(r.minY)
        v.w = Float(r.width)
        v.h = Float(r.height)
        return v
    }

    // MARK: - Hands

    /// A one-hand frame whose thumb/index/middle/ring/little tips (joints
    /// 4/8/12/16/20) are placed at `fingertips`, in that order, and whose
    /// every other joint is gated out by a zero `joint_confidence`.
    ///
    /// Using the confidence array rather than parking unused joints
    /// somewhere harmless keeps the fixture honest about which points the
    /// detector is allowed to see, and exercises the 0.3 gate the shipped
    /// extractor applied per joint.
    static func hands(seq: UInt64 = 1, fingertips: [CGPoint]) -> VCTHandsFrame {
        var hand = VCTHand()
        hand.handedness = .right
        hand.confidence = 0.9
        var joints = [VCTPoint](repeating: point(.zero), count: 21)
        var confidences = [Float](repeating: 0, count: 21)
        let tipIndices = [4, 8, 12, 16, 20]
        for (n, tip) in fingertips.prefix(tipIndices.count).enumerated() {
            joints[tipIndices[n]] = point(tip)
            confidences[tipIndices[n]] = 0.9
        }
        hand.joints = joints
        hand.jointConfidence = confidences

        var frame = VCTHandsFrame()
        frame.header = header(seq: seq)
        frame.hands = [hand]
        return frame
    }

    /// The valid "no hands in frame" publication.
    static func noHands(seq: UInt64 = 1) -> VCTHandsFrame {
        var frame = VCTHandsFrame()
        frame.header = header(seq: seq)
        return frame
    }

    // MARK: - Segmentation

    /// Packs a row-major boolean grid into the proto's MSB-first bitmask —
    /// written out longhand here rather than calling any production helper,
    /// so the packing and the unpacking are genuinely two implementations
    /// that have to agree.
    static func segmentation(seq: UInt64 = 1, cols: Int, rows: Int, cells: [Bool]) -> VCTSegmentationFrame {
        var frame = VCTSegmentationFrame()
        frame.header = header(seq: seq)
        frame.w = UInt32(cols)
        frame.h = UInt32(rows)
        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (i, isSet) in cells.enumerated() where isSet {
            bytes[i / 8] |= 1 << (7 - UInt8(i % 8))
        }
        frame.mask = Data(bytes)
        return frame
    }

    static func segmentation(seq: UInt64 = 1, cols: Int, rows: Int, allPerson: Bool) -> VCTSegmentationFrame {
        segmentation(seq: seq, cols: cols, rows: rows,
                     cells: [Bool](repeating: allPerson, count: cols * rows))
    }

    // MARK: - Joined frames

    /// The shape most detector tests want: one complete, already-joined
    /// frame. Built through the same `VisionFrame.init` the joiner uses, so
    /// the reduction under test is the production one.
    static func frame(seq: UInt64 = 1,
                      box: CGRect? = nil,
                      nose: CGPoint = CGPoint(x: 0.5, y: 0.5),
                      mouth: CGPoint = CGPoint(x: 0.5, y: 0.62),
                      fingertips: [CGPoint] = [],
                      mask: VCTSegmentationFrame? = nil) -> VisionFrame {
        VisionFrame(
            face: box.map { face(seq: seq, box: $0, nose: nose, mouth: mouth) },
            hands: hands(seq: seq, fingertips: fingertips),
            segmentation: mask
        )
    }
}
