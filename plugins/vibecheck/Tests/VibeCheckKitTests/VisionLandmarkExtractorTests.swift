import Testing
import CoreGraphics
@testable import VibeCheckKit

// `VisionLandmarkExtractor` talks to Vision and a live camera buffer, so
// `analyze(_:mirrored:seq:ts:)` itself cannot be unit-tested here — see the
// task report for what was instead checked manually against a running
// camera. What CAN be tested purely, with no camera or Vision involved, is
// the coordinate normalization: it is the one place in the plugin where
// Vision's bottom-left/y-up convention is translated into the viewer-space
// (top-left/y-down) convention every downstream consumer assumes, and the
// x-flip half of that conversion is conditional on `mirrored` — exactly the
// kind of branch that is easy to get backwards silently. All four
// (mirrored/not) x (point/rect) combinations are covered below, plus the
// hair-mask column reversal that has to agree with the point conversion.

// MARK: - Point conversion

@Test func mirroredPointFlipsYOnlyLeavesXAlone() {
    // mirrored == true: the source (built-in front camera) already mirrors
    // x, so x must be passed through untouched. y is always flipped because
    // Vision is y-up.
    let p = VisionLandmarkExtractor.normalize(CGPoint(x: 0.25, y: 0.75), mirrored: true)
    #expect(p.x == 0.25)
    #expect(p.y == 0.25)
}

@Test func unmirroredPointFlipsBothXAndY() {
    // mirrored == false: an external webcam / Continuity Camera is not
    // auto-mirrored, so x must ALSO be flipped or the published coordinate
    // silently disagrees with what the user sees on screen.
    let p = VisionLandmarkExtractor.normalize(CGPoint(x: 0.25, y: 0.75), mirrored: false)
    #expect(p.x == 0.75)
    #expect(p.y == 0.25)
}

@Test func mirroredPointConversionIsItsOwnInverse() {
    let original = CGPoint(x: 0.3, y: 0.8)
    let once = VisionLandmarkExtractor.normalize(original, mirrored: true)
    let twice = VisionLandmarkExtractor.normalize(once, mirrored: true)
    #expect(twice == original)
}

@Test func unmirroredPointConversionIsItsOwnInverse() {
    let original = CGPoint(x: 0.3, y: 0.8)
    let once = VisionLandmarkExtractor.normalize(original, mirrored: false)
    let twice = VisionLandmarkExtractor.normalize(once, mirrored: false)
    #expect(abs(twice.x - original.x) < 1e-9)
    #expect(abs(twice.y - original.y) < 1e-9)
}

// MARK: - Rect conversion

@Test func mirroredRectMapsTopEdgeAndLeavesLeftEdgeAlone() {
    // Vision box in the upper half: y=0.6, height=0.3 -> top edge at y-up
    // 0.9 -> viewer y 0.1. minX is unchanged when mirrored.
    let r = VisionLandmarkExtractor.normalize(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: true)
    #expect(r.minX == 0.1)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

@Test func unmirroredRectMapsTopEdgeAndFlipsLeftEdgeToFormerRightEdge() {
    // Same box, but not mirrored: minX becomes 1 - maxX (0.1 + 0.2 = 0.3, so
    // minX = 1 - 0.3 = 0.7). Width/height are unaffected by the x flip.
    let r = VisionLandmarkExtractor.normalize(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3), mirrored: false)
    #expect(abs(r.minX - 0.7) < 1e-9)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

// MARK: - Hair-mask column reversal
//
// The mask buffer's column order always matches the SOURCE (unmirrored)
// frame. When mirrored, viewer column c samples straight through; when not
// mirrored, it must sample the mirrored column, or the mask disagrees with
// every landmark point emitted alongside it (which DOES get x-flipped in
// that case).

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

@Test func unmirroredMaskColumnReversalIsItsOwnInverse() {
    for c in 0..<8 {
        let once = VisionLandmarkExtractor.sourceColumn(forViewerColumn: c, cols: 8, mirrored: false)
        let twice = VisionLandmarkExtractor.sourceColumn(forViewerColumn: once, cols: 8, mirrored: false)
        #expect(twice == c)
    }
}
