import Foundation
import VCKStubs

/// Eye aspect ratio — how open an eye is, as a dimensionless number.
///
/// This is a measurable property of the body (design §2 test 1), derived from
/// landmarks the face request already computed for someone else (test 2), with
/// a right answer on any fixture (test 3). It is **not** `is_blinking`: where
/// the threshold sits, how long it must hold, and what it means are the
/// consumer's judgement, and blink-jump wanting 0.18 while a drowsiness
/// detector wants 0.22 is exactly why the provider must not pick one.
///
/// ## The formula
///
/// The textbook 6-point EAR (Soukupová & Čech) averages two vertical lid
/// distances and divides by the corner-to-corner distance, and it needs to know
/// which index is which. Vision's eye regions come in different lengths across
/// constellations and this module refuses to hard-code those offsets, so the
/// shipped formula is the same quantity computed without an index map:
///
///   1. the two points furthest apart on the contour are the eye corners, and
///      their separation is the eye's WIDTH;
///   2. the HEIGHT is the contour's full extent perpendicular to that corner
///      axis — the largest excursion above it plus the largest below;
///   3. `EAR = height / width`.
///
/// Both steps run in frame-height units (`Aspect`), so the result is unchanged
/// by the camera's aspect ratio, by how close the user sits, and by head roll —
/// the corner axis rotates with the eye. A fully closed lid collapses the
/// perpendicular extent to zero, so a closed eye reads 0 and an open one reads
/// roughly 0.25–0.35.
///
/// A consumer that genuinely needs the indexed 6-point form drops a tier and
/// derives it from `vision.face.v1` (design §4.4). The points were already
/// computed, so keeping that rung available costs the provider nothing.
public enum EyeAspectRatio {
    /// Fewer than this many contour points cannot express a height: with three
    /// points, two are corners and the single remaining point sits on one side
    /// of the axis only, which halves the extent and silently reports a
    /// half-closed eye. Refusing is the honest answer.
    public static let minimumContourPoints = 4

    /// - Returns: the ratio, or `nil` when the contour is too short or
    ///   degenerate (all points coincident — a real occurrence when a detector
    ///   loses the eye and pins every point to one place). `nil` propagates to
    ///   an ABSENT `ear_l`/`ear_r`, never to 0.0, because 0.0 already means
    ///   something specific and true: the eye is shut.
    public static func value(of contour: some Collection<VCTPoint>, aspect: Aspect) -> Float? {
        guard contour.count >= minimumContourPoints else { return nil }
        let pts = Array(contour)

        // The corners are the furthest-apart pair. O(n^2) over at most eight
        // points, which is cheaper than the branch that would avoid it.
        var widest: Float = 0
        var a = 0
        var b = 0
        for i in 0 ..< pts.count {
            for j in (i + 1) ..< pts.count {
                let d = aspect.distance(pts[i], pts[j])
                if d > widest {
                    widest = d
                    a = i
                    b = j
                }
            }
        }
        guard widest > Geometry.epsilon else { return nil }

        let axis = aspect.delta(from: pts[a], to: pts[b]) * (1 / widest)
        var above: Float = 0   // clockwise-negative side, i.e. up the screen
        var below: Float = 0
        for p in pts {
            // Signed perpendicular offset from the corner axis. y is down, so
            // a positive cross product means the point sits BELOW the axis.
            let offset = axis.cross(aspect.delta(from: pts[a], to: p))
            if offset > below { below = offset }
            if -offset > above { above = -offset }
        }
        return (above + below) / widest
    }

    /// The ratio for one eye of a validated face frame.
    public static func value(of face: FaceLandmarks, eye side: FaceSide, aspect: Aspect) -> Float? {
        value(of: face.points(of: side == .left ? .leftEye : .rightEye), aspect: aspect)
    }
}
