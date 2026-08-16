import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

@Test func aspectDerivesScaleFromHeaderFrame() {
    let a = Aspect(header: vheader(width: 1280, height: 720))
    #expect(isClose(a.xScale, 1280.0 / 720.0, tolerance: 1e-6))
}

@Test func aspectFallsBackToSquareWhenHeaderCarriesNoFrame() {
    // A header with no frame reads back as 0x0 through the generated accessor.
    // Dividing by that is how a NaN gets onto the bus, so presence is checked
    // rather than trusted.
    #expect(Aspect(header: vheaderWithoutFrame()).xScale == 1)
}

@Test func aspectFallsBackToSquareForZeroDimensions() {
    #expect(Aspect(frameWidth: 0, frameHeight: 720).xScale == 1)
    #expect(Aspect(frameWidth: 1280, frameHeight: 0).xScale == 1)
}

@Test func aspectRejectsNonFiniteAndNonPositiveScales() {
    // Non-failable on purpose: one poisoned scale would otherwise turn every
    // signal in the frame into NaN, and NaN compares false against every
    // threshold a consumer might set — a silent permanent stall rather than a
    // visible error.
    #expect(Aspect(xScale: .nan).xScale == 1)
    #expect(Aspect(xScale: .infinity).xScale == 1)
    #expect(Aspect(xScale: 0).xScale == 1)
    #expect(Aspect(xScale: -2).xScale == 1)
}

@Test func aspectMeasuresDistanceInFrameHeightUnits() {
    // On a 2:1 frame, a normalized dx of 0.5 spans the full height's worth of
    // pixels, so it measures 1.0 — and the same span on a square frame
    // measures 0.5. That difference is the whole point: without it, a
    // threshold tuned on one camera is wrong on the next.
    let wide = Aspect(frameWidth: 1280, frameHeight: 640)
    #expect(isClose(wide.distance(vp(0.25, 0.5), vp(0.75, 0.5)), 1.0, tolerance: lengthTolerance))
    #expect(isClose(Aspect.square.distance(vp(0.25, 0.5), vp(0.75, 0.5)), 0.5, tolerance: lengthTolerance))
}

@Test func aspectLeavesVerticalDistanceAlone() {
    let wide = Aspect(frameWidth: 1280, frameHeight: 640)
    #expect(isClose(wide.distance(vp(0.5, 0.2), vp(0.5, 0.7)), 0.5, tolerance: lengthTolerance))
}

@Test func aspectDistanceIsPythagoreanInCorrectedUnits() {
    // 3-4-5 after correction: dx of 0.3 normalized becomes 0.6 corrected on a
    // 2:1 frame; with dy 0.8 the hypotenuse is 1.0.
    let wide = Aspect(frameWidth: 200, frameHeight: 100)
    #expect(isClose(wide.distance(vp(0.1, 0.1), vp(0.4, 0.9)), 1.0, tolerance: lengthTolerance))
}

@Test func vectorAngleIsPositiveClockwiseOnScreen() {
    // y is DOWN, so a vector pointing down-right is at a POSITIVE angle. Every
    // angle this module reports inherits that sign.
    #expect(isClose(Vector2(x: 1, y: 0).angleDegrees!, 0, tolerance: angleTolerance))
    #expect(isClose(Vector2(x: 1, y: 1).angleDegrees!, 45, tolerance: angleTolerance))
    #expect(isClose(Vector2(x: 0, y: 1).angleDegrees!, 90, tolerance: angleTolerance))
    #expect(isClose(Vector2(x: 1, y: -1).angleDegrees!, -45, tolerance: angleTolerance))
}

@Test func vectorAngleIsNilForAZeroLengthVector() {
    // A point has no direction. Reporting 0 would be a fabricated "perfectly
    // level" reading, which downstream is indistinguishable from a real one.
    #expect(Vector2(x: 0, y: 0).angleDegrees == nil)
}

@Test func crossProductSignsMatchTheYDownConvention() {
    let right = Vector2(x: 1, y: 0)
    #expect(right.cross(Vector2(x: 0, y: 1)) > 0)    // below the axis
    #expect(right.cross(Vector2(x: 0, y: -1)) < 0)   // above the axis
}

@Test func foldToHorizontalCollapsesOppositeDirections() {
    // A line has no head and tail: 170 degrees and -10 describe the same tilt.
    #expect(isClose(Geometry.foldToHorizontal(170), -10, tolerance: angleTolerance))
    #expect(isClose(Geometry.foldToHorizontal(-100), 80, tolerance: angleTolerance))
    #expect(isClose(Geometry.foldToHorizontal(12), 12, tolerance: angleTolerance))
    #expect(isClose(Geometry.foldToHorizontal(90), 90, tolerance: angleTolerance))
    #expect(isClose(Geometry.foldToHorizontal(-90), 90, tolerance: angleTolerance))
}
