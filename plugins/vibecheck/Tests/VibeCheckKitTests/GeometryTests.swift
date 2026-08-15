import Testing
import CoreGraphics
@testable import VibeCheckKit

@Test func pointConversionFlipsYAndLeavesXAlone() {
    // Vision: origin bottom-left, y up. Viewer: origin top-left, y down.
    // x is NEVER touched — the front-camera buffer is already mirrored and
    // re-mirroring draws everything on the wrong horizontal side.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75))
    #expect(p.x == 0.25)
    #expect(p.y == 0.25)
}

@Test func rectConversionMapsTopEdgeCorrectly() {
    // A Vision box sitting in the upper half: y=0.6, height=0.3, so its top
    // edge is at y-up 0.9 -> viewer y 0.1. Height is unchanged.
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))
    #expect(r.minX == 0.1)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

@Test func conversionIsItsOwnInverse() {
    let original = CGPoint(x: 0.3, y: 0.8)
    #expect(ViewerSpace.point(ViewerSpace.point(original)) == original)
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
