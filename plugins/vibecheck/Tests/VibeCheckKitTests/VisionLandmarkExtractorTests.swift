import Testing
import CoreGraphics
@testable import VibeCheckKit

// `VisionLandmarkExtractor` talks to Vision and a live camera buffer, so
// `analyze(_:mirrored:seq:ts:)` itself cannot be unit-tested here — see the
// task report for what was instead checked manually against a running
// camera. The point/rect coordinate conversion this type uses is
// `ViewerSpace` (Geometry.swift, tested in `GeometryTests`) — this type
// used to carry its own duplicate `normalize` with a differently-signed x
// rule, which review flagged as two answers to the same question; that
// duplicate is gone, and `extractHand`/`extractFace` now call `ViewerSpace`
// directly. What's left to test purely here is the hair-mask column
// reversal `sourceColumn` performs on `extractHairMask`'s behalf, and that
// it agrees with `ViewerSpace`'s x rule — the two have to stay in lockstep
// or the mask disagrees with every landmark point emitted alongside it.

@Test func mirroredMaskColumnSamplesStraightThrough() {
    for c in 0..<8 {
        #expect(VisionLandmarkExtractor.sourceColumn(forViewerColumn: c, cols: 8, mirrored: true) == c)
    }
}

@Test func unmirroredMaskColumnIsReversed() {
    #expect(VisionLandmarkExtractor.sourceColumn(forViewerColumn: 0, cols: 8, mirrored: false) == 7)
    #expect(VisionLandmarkExtractor.sourceColumn(forViewerColumn: 7, cols: 8, mirrored: false) == 0)
    #expect(VisionLandmarkExtractor.sourceColumn(forViewerColumn: 3, cols: 8, mirrored: false) == 4)
}

// MARK: - Cross-consistency with ViewerSpace
//
// `sourceColumn`'s reversal and `ViewerSpace.point`'s x flip are two
// independent implementations of "flip when not mirrored" that have to
// agree with each other, or the mask and the landmarks it's compared
// against would silently disagree about which side of the frame is which.
// This is the test that would have caught review finding 3 (`ViewerSpace`
// and this type's now-deleted duplicate `normalize` disagreeing) had it
// existed at the time — algebraically both hold today, but nothing short
// of an assertion like this stops a future edit to one from leaving the
// other behind.

@Test func unmirroredMaskColumnAgreesWithPointXFlipRule() {
    let cols = 16
    for c in 0..<cols {
        let sourceCol = VisionLandmarkExtractor.sourceColumn(forViewerColumn: c, cols: cols, mirrored: false)
        let sourceXFromColumn = (CGFloat(sourceCol) + 0.5) / CGFloat(cols)
        let viewerX = (CGFloat(c) + 0.5) / CGFloat(cols)
        // `x -> 1 - x` is its own inverse, so feeding the VIEWER fraction
        // through ViewerSpace.point's unmirrored rule yields exactly the
        // SOURCE fraction that rule expects to have produced that viewer
        // value from — i.e. the same number `sourceColumn` independently
        // computed via column-index arithmetic. If either formula changes
        // without the other, this stops matching.
        let expectedSourceX = ViewerSpace.point(CGPoint(x: viewerX, y: 0), mirrored: false).x
        #expect(abs(sourceXFromColumn - expectedSourceX) < 1e-9)
    }
}
