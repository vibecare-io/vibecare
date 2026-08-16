import CoreGraphics
import Foundation

/// Converts Vision's normalized coordinates (origin bottom-left, y UP) into
/// viewer space (origin top-left, y DOWN) — the frame as the user sees
/// themselves in a mirrored selfie preview, per the vision provider design
/// §4.3 (and architecture v2 §10.1 before it).
///
/// y is always flipped (Vision is y-up). x is flipped ONLY when `mirrored`
/// is false. This used to be documented as "x is deliberately untouched
/// because the front camera is already mirrored by the OS" — that premise
/// was measured false: with `automaticallyAdjustsVideoMirroring` left at
/// its default, BOTH a data-output connection's and a preview layer's
/// `isVideoMirrored` came back `false` for the built-in camera on real
/// hardware. macOS is not silently doing the mirroring for this plugin, so
/// the plugin does it itself, driven by the per-frame flag it actually
/// measured — never by which camera it thinks it has.
///
/// This is the single canonical conversion, moved here verbatim from
/// `plugins/vibecheck/Sources/VibeCheckKit/Geometry.swift` per design §8.
/// Whatever runs the Vision requests calls it for every point and rect it
/// publishes, and whatever encodes the preview JPEG must derive its own flip
/// from the same per-frame `mirrored` value — not reimplement this rule, and
/// not read mirroring state from anywhere else. The two surfaces disagreeing
/// about which flip to apply is exactly the bug this type exists to prevent.
///
/// Everything downstream of this conversion — every function in `VCGeometry`,
/// every coordinate on the wire — is viewer space. There is no second
/// convention anywhere in the provider.
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
    /// `ViewerSpaceTests` for the assertion pinning that agreement). Width
    /// and height are unchanged either way.
    public static func rect(_ r: CGRect, mirrored: Bool) -> CGRect {
        let minX = mirrored ? r.minX : 1 - r.maxX
        return CGRect(x: minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
