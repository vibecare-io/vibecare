import Foundation
import VCKStubs

/// The frame's aspect ratio, and the one place that knows what a "distance"
/// between two normalized landmarks means.
///
/// Every coordinate on the wire is normalized independently in x and y (`Point`
/// in `proto/topics/v1/vision.proto`), so on a 1280x720 frame one unit of
/// normalized x spans 1280 px while one unit of normalized y spans 720. Taking
/// `hypot(dx, dy)` on those numbers directly measures nothing: the same
/// physical gesture reads 1.78x wider on a 16:9 camera than on a 4:3 one, and
/// an angle computed with `atan2` on them is not an angle at all.
///
/// So every metric quantity `VCGeometry` produces is measured in **frame-height
/// units**: y passes through unchanged, x is multiplied by `w / h`. One unit is
/// the height of the frame; a full-width span reads `w / h`. That makes
/// distances and angles properties of the body rather than of the sensor, which
/// is the difference between a threshold that survives a camera swap and one
/// that does not.
///
/// When `Header.frame` is missing or zero — which happens only for a synthetic
/// frame, since the provider always fills it — this degrades to `.square`
/// (`w / h == 1`, i.e. raw normalized distance) rather than refusing to compute.
/// That is deliberate: a signal that is merely aspect-distorted is more useful
/// than an absent one, and the provider's own frames always carry a size.
public struct Aspect: Sendable, Equatable {
    /// Multiply a normalized x (or a normalized dx) by this to get
    /// frame-height units. Always finite and strictly positive.
    public let xScale: Float

    /// A frame whose pixels are as wide as they are tall, i.e. no correction.
    /// Also the fallback for a frame that never declared its size.
    public static let square = Aspect(xScale: 1)

    /// Non-failable on purpose: a nonsensical scale (zero, negative, NaN,
    /// infinite) collapses to 1 rather than propagating a poisoned number into
    /// every downstream signal.
    public init(xScale: Float) {
        self.xScale = (xScale.isFinite && xScale > 0) ? xScale : 1
    }

    public init(frameWidth: UInt32, frameHeight: UInt32) {
        guard frameWidth > 0, frameHeight > 0 else {
            self.init(xScale: 1)
            return
        }
        self.init(xScale: Float(frameWidth) / Float(frameHeight))
    }

    public init(frame: VCTSize) {
        self.init(frameWidth: frame.w, frameHeight: frame.h)
    }

    /// The aspect every published payload's own header implies.
    ///
    /// `hasFrame` is checked as well as the dimensions, which is belt and
    /// braces — an unset `Size` reads back as 0x0 and the zero guard would
    /// catch it anyway. Both stay: the presence check says what is meant, and
    /// the zero guard is what holds if `Size` ever gains a non-zero default.
    public init(header: VCTHeader) {
        if header.hasFrame {
            self.init(frame: header.frame)
        } else {
            self.init(xScale: 1)
        }
    }

    /// The vector `b - a` in frame-height units.
    public func delta(from a: VCTPoint, to b: VCTPoint) -> Vector2 {
        Vector2(x: (b.x - a.x) * xScale, y: b.y - a.y)
    }

    /// `a` expressed in frame-height units, as an offset from the origin.
    public func vector(_ a: VCTPoint) -> Vector2 {
        Vector2(x: a.x * xScale, y: a.y)
    }

    /// Straight-line distance between two normalized landmarks, in
    /// frame-height units.
    public func distance(_ a: VCTPoint, _ b: VCTPoint) -> Float {
        delta(from: a, to: b).length
    }
}

/// A 2D vector already in frame-height units — i.e. one that has been through
/// `Aspect`. Kept distinct from `VCTPoint` on purpose: a `VCTPoint` is a
/// normalized wire coordinate and a `Vector2` is a corrected measurement, and
/// mixing the two silently is the mistake this separation makes hard.
///
/// Orientation is viewer space throughout: +x is the viewer's right, +y is
/// DOWN. Every angle below is therefore positive **clockwise on screen**.
public struct Vector2: Sendable, Equatable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public var length: Float { (x * x + y * y).squareRoot() }

    /// The 2D cross product's z component, `self × other`. Positive when
    /// `other` lies clockwise of `self` on screen (y being down flips the
    /// familiar sign).
    public func cross(_ other: Vector2) -> Float { x * other.y - y * other.x }

    public func dot(_ other: Vector2) -> Float { x * other.x + y * other.y }

    /// Angle off horizontal in DEGREES, positive clockwise on screen, in
    /// (-180, 180]. `nil` for a zero-length vector, which has no direction —
    /// returning 0 there would be a fabricated "perfectly level" reading.
    public var angleDegrees: Float? {
        guard length > Geometry.epsilon else { return nil }
        return Geometry.degrees(atan2(y, x))
    }

    public static func - (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func + (lhs: Vector2, rhs: Vector2) -> Vector2 {
        Vector2(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func * (lhs: Vector2, rhs: Float) -> Vector2 {
        Vector2(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

/// Shared numeric plumbing. Not a namespace for signals — those live in the
/// type that owns them.
public enum Geometry {
    /// Below this, a length in frame-height units is indistinguishable from
    /// zero and any direction derived from it is noise. 1e-6 of a frame height
    /// is well under a thousandth of a pixel on any real sensor.
    public static let epsilon: Float = 1e-6

    public static func degrees(_ radians: Float) -> Float {
        radians * 180 / .pi
    }

    public static func radians(_ degrees: Float) -> Float {
        degrees * .pi / 180
    }

    /// Folds an angle into [-90, 90], the range in which "degrees off
    /// horizontal" is meaningful — a line has no head and tail, so 170 degrees
    /// and -10 degrees describe the same tilt.
    public static func foldToHorizontal(_ degrees: Float) -> Float {
        var d = degrees
        while d > 90 { d -= 180 }
        while d <= -90 { d += 180 }
        return d
    }
}
