import Testing
import CoreGraphics
@testable import vibecare

private func face() -> FaceGeometry {
    // box centered, nose at 0.5/0.55, mouth at 0.5/0.45 (Vision y-up)
    FaceGeometry(box: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.4),
                 nose: CGPoint(x: 0.5, y: 0.55),
                 mouth: CGPoint(x: 0.5, y: 0.45))
}

@Test func nosePickingFiresWhenFingertipAtNose() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.55)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.nosePicking])?.behavior == .nosePicking)
}

@Test func nailBitingFiresWhenFingertipAtMouth() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.45)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.nailBiting])?.behavior == .nailBiting)
}

@Test func hairPullingFiresAboveForehead() {
    // Above face box top (box.maxY = 0.75) → y > 0.75 in the hair zone.
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
}

@Test func noFireWhenHandAwayFromFace() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.1, y: 0.1)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: Set(BFRBBehavior.allCases)) == nil)
}

@Test func disabledBehaviorNeverFires() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.55)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)   // nose point, hair enabled only
}

@Test func noFireWithoutFaceOrHand() {
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(LandmarkFrame(hand: nil, face: face()), enabled: [.nosePicking]) == nil)
    #expect(d.detect(LandmarkFrame(hand: HandGeometry(fingertips: [.zero]), face: nil), enabled: [.nosePicking]) == nil)
}

// MARK: - HairMask-based hair detection

@Test func hairPullingFiresWithMaskPersonTrueAboveForehead() {
    // 4x4 grid, all cells person=true. Fingertip (0.5, 0.8) is above the
    // forehead (box.maxY = 0.75).
    let mask = HairMask(cols: 4, rows: 4, cells: [Bool](repeating: true, count: 16))
    var f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]), face: face())
    f.hairMask = mask
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
}

@Test func hairPullingDoesNotFireWithMaskPersonFalseAboveForehead() {
    // Same position, but mask says "not person" everywhere → no fire, even
    // though the point is above the forehead.
    let mask = HairMask(cols: 4, rows: 4, cells: [Bool](repeating: false, count: 16))
    var f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]), face: face())
    f.hairMask = mask
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

@Test func hairPullingNeverFiresBelowForeheadEvenWithMaskAllTrue() {
    // box.maxY = 0.75; y=0.5 is below the forehead, so the guard should
    // short-circuit before consulting the mask at all.
    let mask = HairMask(cols: 4, rows: 4, cells: [Bool](repeating: true, count: 16))
    var f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]), face: face())
    f.hairMask = mask
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

@Test func hairPullingFiresAboveForeheadViaZoneFallbackWhenNoMask() {
    // Regression: the pre-existing no-mask test must still pass via the
    // geometric-zone fallback.
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]), face: face())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
    #expect(f.hairMask == nil)
}

// MARK: - HairMask.isPerson

@Test func hairMaskIsPersonMapsYUpToRowZeroAtTop() {
    // 2x2 grid: top row (row 0) all true, bottom row (row 1) all false.
    let mask = HairMask(cols: 2, rows: 2, cells: [true, true, false, false])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.9)) == true)   // near top -> row 0
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.1)) == false) // near bottom -> row 1
}

@Test func hairMaskIsPersonClampsAtEdges() {
    let mask = HairMask(cols: 2, rows: 2, cells: [true, true, false, false])
    // Exactly on the [0,1] boundary should not crash and should clamp into
    // the last valid col/row rather than index out of bounds.
    #expect(mask.isPerson(atNormalized: CGPoint(x: 1.0, y: 1.0)) == true)  // top row, last col
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.0, y: 0.0)) == false) // bottom row, first col
}

@Test func hairMaskIsPersonRejectsOutOfRangePoints() {
    let mask = HairMask(cols: 2, rows: 2, cells: [true, true, true, true])
    #expect(mask.isPerson(atNormalized: CGPoint(x: -0.1, y: 0.5)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 1.1)) == false)
}

@Test func hairMaskIsPersonEmptyGridReturnsFalse() {
    let mask = HairMask(cols: 0, rows: 0, cells: [])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.5)) == false)
}
