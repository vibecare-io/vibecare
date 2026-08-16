import CoreGraphics
import Testing
@testable import VCGeometry

// Ported alongside `ViewerSpace` itself from the vibecheck plugin. The
// assertions are unchanged on purpose: moving capture between plugins must not
// quietly move a coordinate by a frame width, and these are the only things
// that would notice.

@Test func viewerSpaceMirroredPointFlipsYOnly() {
    // Vision: origin bottom-left, y up. Viewer: origin top-left, y down.
    // mirrored == true means the source connection reported itself as already
    // mirrored, so x passes through untouched.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75), mirrored: true)
    #expect(p.x == 0.25)
    #expect(p.y == 0.25)
}

@Test func viewerSpaceUnmirroredPointFlipsBothAxes() {
    // mirrored == false is what the built-in Mac camera actually reports: it
    // has position == .unspecified, so automaticallyAdjustsVideoMirroring
    // never engages and nothing arrives pre-mirrored. The provider flips x
    // itself or every landmark lands on the wrong side of the frame.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75), mirrored: false)
    #expect(p.x == 0.75)
    #expect(p.y == 0.25)
}

@Test func viewerSpaceMirroredRectMapsTopEdge() {
    // A Vision box in the upper half: y = 0.6, height = 0.3, so its top edge
    // sits at y-up 0.9 and becomes viewer y 0.1.
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: true)
    #expect(r.minX == 0.1)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

@Test func viewerSpaceUnmirroredRectFlipsLeftEdgeToFormerRightEdge() {
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: false)
    #expect(abs(r.minX - 0.7) < 1e-9)   // 1 - (0.1 + 0.2)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

// Cross-consistency between the two conversions. Each is pinned individually
// above, but nothing stops a future edit from changing one formula and not the
// other — and a rect and a point disagreeing about which side of the frame is
// which is precisely the bug that existed while this rule was duplicated in
// two files.

@Test func viewerSpaceMirroredRectMidpointAgreesWithPointConversion() {
    let original = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)
    let convertedRect = ViewerSpace.rect(original, mirrored: true)
    let convertedMidpoint = ViewerSpace.point(CGPoint(x: original.midX, y: original.midY), mirrored: true)
    #expect(abs(convertedRect.midX - convertedMidpoint.x) < 1e-9)
    #expect(abs(convertedRect.midY - convertedMidpoint.y) < 1e-9)
}

@Test func viewerSpaceUnmirroredRectMidpointAgreesWithPointConversion() {
    let original = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)
    let convertedRect = ViewerSpace.rect(original, mirrored: false)
    let convertedMidpoint = ViewerSpace.point(CGPoint(x: original.midX, y: original.midY), mirrored: false)
    #expect(abs(convertedRect.midX - convertedMidpoint.x) < 1e-9)
    #expect(abs(convertedRect.midY - convertedMidpoint.y) < 1e-9)
}

@Test func viewerSpaceConversionIsItsOwnInverse() {
    // The conversion is an involution in both modes, which is what lets the
    // preview flip and the landmark flip be derived from one flag without
    // anyone tracking how many times it has been applied.
    for mirrored in [true, false] {
        let original = CGPoint(x: 0.31, y: 0.77)
        let round = ViewerSpace.point(ViewerSpace.point(original, mirrored: mirrored), mirrored: mirrored)
        #expect(abs(round.x - original.x) < 1e-9)
        #expect(abs(round.y - original.y) < 1e-9)
    }
}
