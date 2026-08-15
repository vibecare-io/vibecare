import Testing
import CoreGraphics
@testable import VibeCheckKit

// Face box in VIEWER space: top edge at y=0.3, bottom at y=0.7.
private func face() -> FaceGeometry {
    FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                 nose: CGPoint(x: 0.5, y: 0.5),
                 mouth: CGPoint(x: 0.5, y: 0.62))
}

@Test func fingertipOnTheNoseFiresNosePicking() {
    let d = BFRBDetector(sensitivity: 0.5)     // radius 0.08
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.52, y: 0.5)]),
                              face: face())
    #expect(d.detect(frame, enabled: [.nosePicking])?.behavior == .nosePicking)
}

@Test func hairContactRequiresBeingABOVETheForehead() {
    // In viewer space "above the forehead" is a SMALLER y than box.minY.
    // This is the assertion the coordinate flip inverts; getting it backwards
    // makes the detector fire on the chin instead of the scalp.
    let d = BFRBDetector(sensitivity: 0.5)
    let above = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.2)]),
                              face: face())
    let below = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]),
                              face: face())
    #expect(d.detect(above, enabled: [.hairPulling])?.behavior == .hairPulling)
    #expect(d.detect(below, enabled: [.hairPulling]) == nil)
}

@Test func hairZoneSitsAboveTheFaceBox() {
    let zone = BFRBDetector.hairZone(for: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4))
    #expect(abs(zone.maxY - 0.3) < 1e-9)      // bottom of the band meets the top of the face
    #expect(abs(zone.height - 0.2) < 1e-9)    // half the face height
    #expect(abs(zone.minX - 0.37) < 1e-9)     // padded 15% of face width
}

@Test func noHandOrNoFaceNeverFires() {
    let d = BFRBDetector(sensitivity: 1.0)
    #expect(d.detect(LandmarkFrame(hand: nil, face: face()), enabled: [.nosePicking]) == nil)
    #expect(d.detect(LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                                   face: nil), enabled: [.nosePicking]) == nil)
}

@Test func disabledBehaviorsNeverFire() {
    let d = BFRBDetector(sensitivity: 0.5)
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                              face: face())
    #expect(d.detect(frame, enabled: []) == nil)
}

@Test func nosePickingWinsOverNailBitingForTheSameFingertip() {
    // First-match-wins, and the order within a fingertip is nose -> mouth ->
    // hair. A tip equidistant from nose and mouth reports nose-picking.
    let d = BFRBDetector(sensitivity: 1.0)     // radius 0.12, both in range
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.56)]),
                              face: face())
    #expect(d.detect(frame, enabled: [.nosePicking, .nailBiting])?.behavior == .nosePicking)
}

@Test func maskOverridesTheGeometricZoneWhenPresent() {
    let d = BFRBDetector(sensitivity: 0.5)
    let allFalse = HairMask(cols: 2, rows: 2, cells: [false, false, false, false])
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.2)]),
                              face: face(), hairMask: allFalse)
    // Inside the geometric zone, but the mask says "not person" — mask wins.
    #expect(d.detect(frame, enabled: [.hairPulling]) == nil)
}

// MARK: - Remaining tests ported from the original vibecareTests suite
//
// These are mechanically inverted by routing the original Vision-space
// (y-up) literals through `ViewerSpace.point`/`ViewerSpace.rect` — the same
// conversion Task 7 built and tested — rather than hand-recomputing the
// arithmetic, so the inversion itself can't be gotten backwards here.
// `mirrored: true` throughout: these fixtures model a source that reports
// itself already mirrored, matching the original vibecareTests literals
// they were mechanically inverted from (x untouched, y flipped only).

/// Mechanical inversion of the original vibecareTests `face()` fixture
/// (box (0.35, 0.35, 0.3, 0.4) y-up, nose (0.5, 0.55), mouth (0.5, 0.45)).
private func legacyFace() -> FaceGeometry {
    FaceGeometry(box: ViewerSpace.rect(CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.4), mirrored: true),
                 nose: ViewerSpace.point(CGPoint(x: 0.5, y: 0.55), mirrored: true),
                 mouth: ViewerSpace.point(CGPoint(x: 0.5, y: 0.45), mirrored: true))
}

@Test func nailBitingFiresWhenFingertipAtMouth() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [ViewerSpace.point(CGPoint(x: 0.5, y: 0.45), mirrored: true)]),
                          face: legacyFace())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.nailBiting])?.behavior == .nailBiting)
}

@Test func noFireWhenHandAwayFromFace() {
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [ViewerSpace.point(CGPoint(x: 0.1, y: 0.1), mirrored: true)]),
                          face: legacyFace())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: Set(BFRBBehavior.allCases)) == nil)
}

@Test func disabledBehaviorNeverFires() {
    // nose point, hair enabled only
    let f = LandmarkFrame(hand: HandGeometry(fingertips: [ViewerSpace.point(CGPoint(x: 0.5, y: 0.55), mirrored: true)]),
                          face: legacyFace())
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

@Test func hairPullingFiresWithMaskPersonTrueAboveForehead() {
    // 4x4 grid, all cells person=true. Fingertip above the forehead.
    let mask = HairMask(cols: 4, rows: 4, cells: [Bool](repeating: true, count: 16))
    var f = LandmarkFrame(hand: HandGeometry(fingertips: [ViewerSpace.point(CGPoint(x: 0.5, y: 0.8), mirrored: true)]),
                          face: legacyFace())
    f.hairMask = mask
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
}

@Test func hairPullingNeverFiresBelowForeheadEvenWithMaskAllTrue() {
    // Below the forehead; the guard should short-circuit before consulting
    // the mask at all, even though the mask says "person" everywhere.
    let mask = HairMask(cols: 4, rows: 4, cells: [Bool](repeating: true, count: 16))
    var f = LandmarkFrame(hand: HandGeometry(fingertips: [ViewerSpace.point(CGPoint(x: 0.5, y: 0.5), mirrored: true)]),
                          face: legacyFace())
    f.hairMask = mask
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}
