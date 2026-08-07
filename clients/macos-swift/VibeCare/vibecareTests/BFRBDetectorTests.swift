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
