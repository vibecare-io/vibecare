import Testing
import CoreGraphics
import Foundation
import VCKStubs
@testable import VibeCheckKit

// The same fourteen behaviour assertions this suite made before the vision
// cutover, with their INPUTS re-expressed as bus payloads: a `VisionFrame`
// joined from a real `VCTFaceFrame`/`VCTHandsFrame`/`VCTSegmentationFrame`
// instead of a locally-built `LandmarkFrame`. Not one expected value moved,
// which is the point — the radius formula, the per-fingertip
// nose -> mouth -> hair order, the above-the-forehead guard and the
// mask-beats-geometry rule all survive the change of input type.

// Face box in VIEWER space: top edge at y=0.3, bottom at y=0.7.
private let faceBox = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
private let faceNose = CGPoint(x: 0.5, y: 0.5)
private let faceMouth = CGPoint(x: 0.5, y: 0.62)

private func frame(fingertips: [CGPoint],
                   mask: VCTSegmentationFrame? = nil,
                   withFace: Bool = true) -> VisionFrame {
    Fixtures.frame(box: withFace ? faceBox : nil,
                   nose: faceNose, mouth: faceMouth,
                   fingertips: fingertips, mask: mask)
}

@Test func fingertipOnTheNoseFiresNosePicking() {
    let d = BFRBDetector(sensitivity: 0.5)     // radius 0.08
    let f = frame(fingertips: [CGPoint(x: 0.52, y: 0.5)])
    #expect(d.detect(f, enabled: [.nosePicking])?.behavior == .nosePicking)
}

@Test func hairContactRequiresBeingABOVETheForehead() {
    // In viewer space "above the forehead" is a SMALLER y than box.minY.
    // This is the assertion the coordinate flip inverts; getting it backwards
    // makes the detector fire on the chin instead of the scalp.
    let d = BFRBDetector(sensitivity: 0.5)
    let above = frame(fingertips: [CGPoint(x: 0.5, y: 0.2)])
    let below = frame(fingertips: [CGPoint(x: 0.5, y: 0.8)])
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
    // No hands: the valid "nothing detected" hands publication, which is a
    // message and not an absence — the detector must read it as "no
    // fingertips", never stall or reuse the previous frame's.
    let handless = VisionFrame(face: Fixtures.face(box: faceBox, nose: faceNose, mouth: faceMouth),
                               hands: Fixtures.noHands())
    #expect(d.detect(handless, enabled: [.nosePicking]) == nil)
    // No face: same, from the other side.
    let faceless = VisionFrame(face: Fixtures.noFace(),
                               hands: Fixtures.hands(fingertips: [CGPoint(x: 0.5, y: 0.5)]))
    #expect(d.detect(faceless, enabled: [.nosePicking]) == nil)
}

@Test func disabledBehaviorsNeverFire() {
    let d = BFRBDetector(sensitivity: 0.5)
    let f = frame(fingertips: [CGPoint(x: 0.5, y: 0.5)])
    #expect(d.detect(f, enabled: []) == nil)
}

@Test func nosePickingWinsOverNailBitingForTheSameFingertip() {
    // First-match-wins, and the order within a fingertip is nose -> mouth ->
    // hair. A tip equidistant from nose and mouth reports nose-picking.
    let d = BFRBDetector(sensitivity: 1.0)     // radius 0.12, both in range
    let f = frame(fingertips: [CGPoint(x: 0.5, y: 0.56)])
    #expect(d.detect(f, enabled: [.nosePicking, .nailBiting])?.behavior == .nosePicking)
}

@Test func maskOverridesTheGeometricZoneWhenPresent() {
    let d = BFRBDetector(sensitivity: 0.5)
    let allFalse = Fixtures.segmentation(cols: 2, rows: 2, allPerson: false)
    let f = frame(fingertips: [CGPoint(x: 0.5, y: 0.2)], mask: allFalse)
    // Inside the geometric zone, but the mask says "not person" — mask wins.
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

// MARK: - Remaining tests ported from the original vibecareTests suite
//
// These were originally written against Vision's own convention (normalized,
// origin bottom-left, y UP) and were mechanically inverted through
// `ViewerSpace` when this plugin still owned that conversion. `ViewerSpace`
// now lives in the vision plugin — every coordinate arriving over the bus is
// already viewer space — so the inverted values are written out directly,
// with the Vision-space original noted alongside each so the inversion
// remains checkable by hand.

/// Vision-space original: box (0.35, 0.35, 0.3, 0.4), nose (0.5, 0.55),
/// mouth (0.5, 0.45). Inverted (y' = 1 - y, box y' = 1 - maxY, x untouched
/// because these fixtures model an already-mirrored source).
private let legacyBox = CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.4)
private let legacyNose = CGPoint(x: 0.5, y: 0.45)
private let legacyMouth = CGPoint(x: 0.5, y: 0.55)

private func legacyFrame(fingertips: [CGPoint], mask: VCTSegmentationFrame? = nil) -> VisionFrame {
    Fixtures.frame(box: legacyBox, nose: legacyNose, mouth: legacyMouth,
                   fingertips: fingertips, mask: mask)
}

@Test func nailBitingFiresWhenFingertipAtMouth() {
    // Vision-space (0.5, 0.45) -> viewer (0.5, 0.55), i.e. on the mouth.
    let f = legacyFrame(fingertips: [CGPoint(x: 0.5, y: 0.55)])
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.nailBiting])?.behavior == .nailBiting)
}

@Test func noFireWhenHandAwayFromFace() {
    // Vision-space (0.1, 0.1) -> viewer (0.1, 0.9).
    let f = legacyFrame(fingertips: [CGPoint(x: 0.1, y: 0.9)])
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: Set(BFRBBehavior.allCases)) == nil)
}

@Test func disabledBehaviorNeverFires() {
    // On the nose, with hair enabled only.
    let f = legacyFrame(fingertips: [CGPoint(x: 0.5, y: 0.45)])
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

@Test func hairPullingFiresWithMaskPersonTrueAboveForehead() {
    // 4x4 grid, all cells person=true. Vision-space (0.5, 0.8) -> viewer
    // (0.5, 0.2), which is above the box top at 0.25.
    let mask = Fixtures.segmentation(cols: 4, rows: 4, allPerson: true)
    let f = legacyFrame(fingertips: [CGPoint(x: 0.5, y: 0.2)], mask: mask)
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
}

@Test func hairPullingNeverFiresBelowForeheadEvenWithMaskAllTrue() {
    // Below the forehead; the guard should short-circuit before consulting
    // the mask at all, even though the mask says "person" everywhere.
    let mask = Fixtures.segmentation(cols: 4, rows: 4, allPerson: true)
    let f = legacyFrame(fingertips: [CGPoint(x: 0.5, y: 0.5)], mask: mask)
    let d = BFRBDetector(sensitivity: 0.5)
    #expect(d.detect(f, enabled: [.hairPulling]) == nil)
}

// MARK: - New guard the cutover made possible to get wrong
//
// The empty "no person segmented" publication is a real message, and the
// detector must read it as "no mask" — falling through to the geometric hair
// zone — rather than as "the mask says no". Collapsing the two would
// silently disable hair-pulling detection for every frame in which the
// segmentation model found nobody, which is exactly when a hand raised to
// the scalp is most likely to have confused it.
@Test func anEmptySegmentationFrameFallsBackToTheGeometricZoneRatherThanSuppressing() {
    let d = BFRBDetector(sensitivity: 0.5)
    var empty = Fixtures.segmentation(cols: 0, rows: 0, cells: [])
    empty.mask = Data()
    let f = frame(fingertips: [CGPoint(x: 0.5, y: 0.2)], mask: empty)
    #expect(d.detect(f, enabled: [.hairPulling])?.behavior == .hairPulling)
}
