import SwiftUI

/// Draws the face box, detection zones, and fingertips over the mirrored
/// preview. Input points are Vision-normalized with origin bottom-left, so we
/// flip y for SwiftUI (origin top-left). We do NOT flip x: the front-camera
/// sample buffer Vision analyzes is already mirrored to match the mirrored
/// preview layer, so the landmark x already aligns with what's on screen —
/// re-mirroring here would draw everything on the wrong horizontal side.
///
/// The preview uses `videoGravity = .resizeAspectFill`, so the displayed
/// video is cropped/zoomed to fill the pane rather than stretched to it.
/// Points must therefore be mapped through the aspect-FILL displayed video
/// rect (computed from `frame.imageSize` vs the pane size), not the full
/// pane rect, or the overlay drifts off the face whenever the pane's aspect
/// ratio differs from the camera frame's.
struct DetectionOverlay: View {
    let frame: LandmarkFrame
    let enabledBehaviors: Set<BFRBBehavior>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // frame aspect; fall back to 16:9 if imageSize not yet known
            let fa: CGFloat = frame.imageSize.height > 0 ? frame.imageSize.width / frame.imageSize.height : 16.0 / 9.0
            let viewAspect = w / h
            // aspect-FILL: video covers the view, cropping the longer dimension.
            // (Ternary, not if/else — this closure is a SwiftUI @ViewBuilder body,
            // and a plain if/else statement here is parsed as view-building control
            // flow rather than a value computation.)
            let dispW: CGFloat = viewAspect > fa ? w : h * fa   // view wider than frame → fill width; else fill height
            let dispH: CGFloat = viewAspect > fa ? w / fa : h
            let ox = (w - dispW) / 2
            let oy = (h - dispH) / 2
            let pt: (CGPoint) -> CGPoint = { CGPoint(x: ox + $0.x * dispW, y: oy + (1 - $0.y) * dispH) }

            Canvas { ctx, _ in
                if let face = frame.face {
                    // Vision box origin is bottom-left; its top-left on screen is
                    // (minX, maxY) mapped through pt (x unflipped, y flipped).
                    let origin = pt(CGPoint(x: face.box.minX, y: face.box.maxY))
                    let r = CGRect(x: origin.x,
                                   y: origin.y,
                                   width: face.box.width * dispW,
                                   height: face.box.height * dispH)
                    ctx.stroke(Path(r), with: .color(.cyan), lineWidth: 2)

                    if enabledBehaviors.contains(.hairPulling), let mask = frame.hairMask {
                        drawHairMask(ctx: &ctx, mask: mask, box: face.box, pt: pt, dispW: dispW, dispH: dispH)
                    }
                    if enabledBehaviors.contains(.nosePicking) {
                        drawTargetMarker(ctx: &ctx, at: pt(face.nose), color: .green)
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

    /// Draws the person-segmentation mask cells that are above the forehead
    /// as translucent blue squares — a head/hair silhouette instead of the
    /// old geometric rectangle. Uses the SAME mask `BFRBDetector` samples
    /// for the hair-pulling trigger, so the drawn overlay and the actual
    /// detection region can never drift apart. Cells at/below the forehead
    /// are skipped so the face itself isn't tinted.
    private func drawHairMask(ctx: inout GraphicsContext, mask: HairMask, box: CGRect,
                               pt: (CGPoint) -> CGPoint, dispW: CGFloat, dispH: CGFloat) {
        guard mask.cols > 0, mask.rows > 0 else { return }
        let cellW = dispW / CGFloat(mask.cols)
        let cellH = dispH / CGFloat(mask.rows)
        for r in 0..<mask.rows {
            let yUpTop = 1 - CGFloat(r) / CGFloat(mask.rows)          // cell's top edge, y-up
            guard yUpTop > box.maxY else { continue }                  // skip at/below forehead
            for c in 0..<mask.cols where mask.cells[r * mask.cols + c] {
                let topLeft = CGPoint(x: CGFloat(c) / CGFloat(mask.cols), y: yUpTop)
                let origin = pt(topLeft)
                let cellRect = CGRect(x: origin.x, y: origin.y, width: cellW, height: cellH)
                ctx.fill(Path(cellRect), with: .color(.blue.opacity(0.30)))
            }
        }
    }

    /// A small target-ring marker for point-based behaviors (nose/mouth).
    private func drawTargetMarker(ctx: inout GraphicsContext, at center: CGPoint, color: Color) {
        let radius: CGFloat = 7
        let r = CGRect(x: center.x - radius, y: center.y - radius,
                        width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 2)
    }
}
