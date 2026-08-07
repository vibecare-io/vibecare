import SwiftUI

/// Draws the face box, detection zones, and fingertips over the mirrored
/// preview. Input points are Vision-normalized with origin bottom-left, so we
/// flip y for SwiftUI (origin top-left). We do NOT flip x: the front-camera
/// sample buffer Vision analyzes is already mirrored to match the mirrored
/// preview layer, so the landmark x already aligns with what's on screen —
/// re-mirroring here would draw everything on the wrong horizontal side.
struct DetectionOverlay: View {
    let frame: LandmarkFrame
    let enabledBehaviors: Set<BFRBBehavior>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pt: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }

            Canvas { ctx, _ in
                if let face = frame.face {
                    // Vision box origin is bottom-left; its top-left on screen is
                    // (minX, maxY) mapped through pt (x unflipped, y flipped).
                    let origin = pt(CGPoint(x: face.box.minX, y: face.box.maxY))
                    let r = CGRect(x: origin.x,
                                   y: origin.y,
                                   width: face.box.width * w,
                                   height: face.box.height * h)
                    ctx.stroke(Path(r), with: .color(.cyan), lineWidth: 2)

                    if enabledBehaviors.contains(.hairPulling) {
                        drawHairZone(ctx: &ctx, box: face.box, pt: pt, w: w, h: h)
                    }
                    if enabledBehaviors.contains(.nosePicking) {
                        drawTargetMarker(ctx: &ctx, at: pt(face.nose), color: .orange)
                    }
                    if enabledBehaviors.contains(.nailBiting) {
                        drawTargetMarker(ctx: &ctx, at: pt(face.mouth), color: .orange)
                    }
                }
                if let hand = frame.hand {
                    for tip in hand.fingertips {
                        let c = pt(tip)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                                 with: .color(.yellow))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Translucent blue detection-zone rect for hair-pulling, computed from
    /// the SAME Vision-space geometry `BFRBDetector` uses to trigger — this
    /// is a geometric zone, not a hair-shaped mask (native macOS has no hair
    /// segmentation).
    private func drawHairZone(ctx: inout GraphicsContext, box: CGRect,
                               pt: (CGPoint) -> CGPoint, w: CGFloat, h: CGFloat) {
        let zone = BFRBDetector.hairZone(for: box)
        let origin = pt(CGPoint(x: zone.minX, y: zone.maxY))
        let r = CGRect(x: origin.x,
                        y: origin.y,
                        width: zone.width * w,
                        height: zone.height * h)
        let path = Path(roundedRect: r, cornerRadius: 8)
        ctx.fill(path, with: .color(.blue.opacity(0.25)))
        ctx.stroke(path, with: .color(.blue.opacity(0.6)), lineWidth: 1.5)
    }

    /// A small target-ring marker for point-based behaviors (nose/mouth).
    private func drawTargetMarker(ctx: inout GraphicsContext, at center: CGPoint, color: Color) {
        let radius: CGFloat = 7
        let r = CGRect(x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 2)
    }
}
