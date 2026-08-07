import SwiftUI

/// Draws the face box, detection zones, and fingertips over the mirrored
/// preview. Input points are Vision-normalized (y up); we flip y for SwiftUI
/// (y down) and mirror x to match the mirrored preview.
struct DetectionOverlay: View {
    let frame: LandmarkFrame

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pt: (CGPoint) -> CGPoint = { CGPoint(x: (1 - $0.x) * w, y: (1 - $0.y) * h) }

            Canvas { ctx, _ in
                if let face = frame.face {
                    let r = CGRect(x: (1 - face.box.maxX) * w,
                                   y: (1 - face.box.maxY) * h,
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
