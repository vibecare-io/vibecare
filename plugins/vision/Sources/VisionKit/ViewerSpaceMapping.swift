import CoreGraphics
import Foundation
import VCKStubs

/// Converts Vision's normalized coordinates (origin bottom-left, y UP) into
/// **viewer space** (origin top-left, y DOWN) — the frame as the user sees
/// themselves in a mirrored selfie preview, per the vision design §4.3.
///
/// y is always flipped, because Vision is y-up. x is flipped **only when
/// `mirrored` is false**. That condition is the whole reason this type exists
/// as one shared implementation: `AppleVisionAnalyzer` flips every landmark
/// through here, `AppleVisionAnalyzer.packMask` flips mask columns through
/// `sourceColumn` below, and `JPEGEncoder.encode` flips the preview image on
/// the identical `!mirrored` test. Three surfaces, one rule — the bug this
/// prevents is the overlay landing on the wrong side of the user's face
/// because two of them disagreed.
///
/// `mirrored` is read from `AVCaptureConnection.isVideoMirrored` **per frame**,
/// never cached and never inferred from `AVCaptureDevice.position`. That is
/// not caution for its own sake: it was measured that the built-in Mac camera
/// reports `position = .unspecified`, so `automaticallyAdjustsVideoMirroring`
/// never engages, both the data-output and preview connections report
/// `isVideoMirrored == false`, and nothing arrives pre-mirrored. The provider
/// therefore does the mirroring itself, driven by the flag the connection
/// actually reported for that one frame.
///
/// Deliberately `internal`. The vision design §8 moves the shipped
/// `ViewerSpace` into the `VCGeometry` target; keeping this copy module-private
/// means the two can coexist during the split without an ambiguous-name build
/// error, and means nothing outside `VisionKit` can start depending on the
/// wrong one. Nothing outside this module needs it: every coordinate that
/// leaves `VisionKit` is already in viewer space.
enum ViewerSpaceMapping {
    /// A Vision-space normalized point, in viewer space.
    static func point(_ p: CGPoint, mirrored: Bool) -> CGPoint {
        CGPoint(x: mirrored ? p.x : 1 - p.x, y: 1 - p.y)
    }

    /// A Vision-space normalized rect, in viewer space.
    ///
    /// The rect's TOP edge is at y-up `maxY`, which becomes viewer `1 - maxY`.
    /// When not mirrored the right edge (`maxX`) becomes the new left edge, so
    /// the new `minX` is `1 - maxX` — the same rule `point` applies to x, which
    /// is why `rect(r, mirrored:).midX` always equals `point(mid(r),
    /// mirrored:).x`. Width and height are unchanged either way.
    static func rect(_ r: CGRect, mirrored: Bool) -> CGRect {
        CGRect(x: mirrored ? r.minX : 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Maps a viewer-space grid column back to the column to sample from the
    /// (unflipped) segmentation buffer.
    ///
    /// This is `point`'s "flip x when not mirrored" rule expressed as a column
    /// index rather than a `[0,1]` coordinate. `ViewerSpaceMappingTests` pins
    /// the two against each other directly, because a mask mirrored the other
    /// way from the landmarks published alongside it is a defect no single
    /// surface's own test can catch.
    static func sourceColumn(forViewerColumn c: Int, cols: Int, mirrored: Bool) -> Int {
        mirrored ? c : (cols - 1 - c)
    }

    /// Vision-space point straight to the wire type, so no call site ever
    /// holds a `CGPoint` it might forget to convert.
    static func protoPoint(_ p: CGPoint, mirrored: Bool) -> VCTPoint {
        let v = point(p, mirrored: mirrored)
        var out = VCTPoint()
        out.x = Float(v.x)
        out.y = Float(v.y)
        return out
    }

    static func protoRect(_ r: CGRect, mirrored: Bool) -> VCTRect {
        let v = rect(r, mirrored: mirrored)
        var out = VCTRect()
        out.x = Float(v.minX)
        out.y = Float(v.minY)
        out.w = Float(v.width)
        out.h = Float(v.height)
        return out
    }
}
