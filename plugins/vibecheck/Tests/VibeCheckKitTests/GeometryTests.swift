import Testing
import CoreGraphics
@testable import VibeCheckKit

@Test func mirroredPointFlipsYOnlyLeavesXAlone() {
    // Vision: origin bottom-left, y up. Viewer: origin top-left, y down.
    // mirrored == true: the source connection reported itself as already
    // mirrored, so x passes through untouched.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75), mirrored: true)
    #expect(p.x == 0.25)
    #expect(p.y == 0.25)
}

@Test func unmirroredPointFlipsBothXAndY() {
    // mirrored == false: measured true even for the built-in camera on real
    // hardware (see CameraSession.configure()'s comment and the Task 11/12
    // report) — macOS does not reliably auto-mirror the data-output
    // connection, so the plugin must flip x itself or every landmark lands
    // on the wrong side of the frame.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75), mirrored: false)
    #expect(p.x == 0.75)
    #expect(p.y == 0.25)
}

@Test func mirroredRectConversionMapsTopEdgeCorrectly() {
    // A Vision box sitting in the upper half: y=0.6, height=0.3, so its top
    // edge is at y-up 0.9 -> viewer y 0.1. minX/width/height unchanged.
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: true)
    #expect(r.minX == 0.1)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

@Test func unmirroredRectConversionFlipsLeftEdgeToFormerRightEdge() {
    // Same box, not mirrored: minX becomes 1 - maxX (1 - (0.1+0.2) = 0.7).
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: false)
    #expect(abs(r.minX - 0.7) < 1e-9)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

// Cross-consistency between the point and rect conversions: converting the
// rect and reading its midX must agree with converting the point at the
// ORIGINAL rect's midpoint directly. Both individually pin their own
// values above, but nothing stops a future edit from changing one formula
// and not the other — this is the assertion that would catch exactly that,
// which the review flagged as the gap that let `ViewerSpace` and
// `VisionLandmarkExtractor`'s now-deleted duplicate `normalize` disagree.

@Test func mirroredRectMidpointAgreesWithPointConversion() {
    let original = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)
    let convertedRect = ViewerSpace.rect(original, mirrored: true)
    let convertedMidpoint = ViewerSpace.point(CGPoint(x: original.midX, y: original.midY), mirrored: true)
    #expect(abs(convertedRect.midX - convertedMidpoint.x) < 1e-9)
}

@Test func unmirroredRectMidpointAgreesWithPointConversion() {
    let original = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)
    let convertedRect = ViewerSpace.rect(original, mirrored: false)
    let convertedMidpoint = ViewerSpace.point(CGPoint(x: original.midX, y: original.midY), mirrored: false)
    #expect(abs(convertedRect.midX - convertedMidpoint.x) < 1e-9)
}

@Test func hairMaskRowZeroIsTopInViewerSpace() {
    // 2 cols x 2 rows, only the top-left cell set.
    let mask = HairMask(cols: 2, rows: 2, cells: [true, false, false, false])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.25)) == true)   // top-left
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.75, y: 0.25)) == false)  // top-right
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.75)) == false)  // bottom-left
}

@Test func hairMaskClampsAndRejectsOutOfRange() {
    let mask = HairMask(cols: 2, rows: 2, cells: [true, true, true, true])
    #expect(mask.isPerson(atNormalized: CGPoint(x: -0.1, y: 0.5)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 1.1)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 1.0, y: 1.0)) == true)   // clamped edge
}

@Test func emptyMaskIsNeverPerson() {
    let mask = HairMask(cols: 0, rows: 0, cells: [])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.5)) == false)
}

@Test func everyBehaviorHasNonEmptyPresentation() {
    for b in BFRBBehavior.allCases {
        #expect(!b.label.isEmpty)
        #expect(!b.nudge.isEmpty)
        #expect(!b.alertIcon.isEmpty)
        #expect(!b.defaultIconId.isEmpty)
    }
}
