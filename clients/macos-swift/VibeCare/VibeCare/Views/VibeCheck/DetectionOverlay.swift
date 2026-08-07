import SwiftUI

/// Draws the face box, detection zones, and fingertips over the mirrored
/// preview. Input points are Vision-normalized with origin bottom-left, so we
/// flip y for SwiftUI (origin top-left). We do NOT flip x: the front-camera
/// sample buffer Vision analyzes is already mirrored to match the mirrored
/// preview layer, so the landmark x already aligns with what's on screen —
/// re-mirroring here would draw everything on the wrong horizontal side.
struct DetectionOverlay: View {
    let frame: LandmarkFrame

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
}
