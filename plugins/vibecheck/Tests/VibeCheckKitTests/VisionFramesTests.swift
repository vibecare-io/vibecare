import Testing
import CoreGraphics
import Foundation
import VCKStubs
@testable import VibeCheckKit

// Replaces GeometryTests.swift. The `ViewerSpace` conversion it used to pin
// moved to the vision plugin with the camera, and `HairMask` was deleted in
// favour of the packed bitmask on `vision.segmentation.v1` — so what this
// suite pins now is the ADAPTATION: turning three bus payloads into the
// handful of values `BFRBDetector` measures against, and doing it in a way
// that fails loudly rather than quietly when the provider's face
// constellation is not the one this plugin believes in.

// MARK: - Face anchors, landmark path

@Test func faceAnchorsReadTheNoseAndOuterLipsRegionsOutOfThePointCloud() throws {
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    let nose = CGPoint(x: 0.5, y: 0.5)
    let mouth = CGPoint(x: 0.5, y: 0.62)
    let anchors = try #require(FaceAnchors.from(Fixtures.face(box: box, nose: nose, mouth: mouth)))

    #expect(anchors.source == .landmarks)
    #expect(abs(anchors.nose.x - nose.x) < 1e-6)
    #expect(abs(anchors.nose.y - nose.y) < 1e-6)
    #expect(abs(anchors.mouth.x - mouth.x) < 1e-6)
    #expect(abs(anchors.mouth.y - mouth.y) < 1e-6)
    #expect(abs(anchors.box.minY - box.minY) < 1e-6)
}

@Test func theNoseAnchorIsACentroidNotTheFirstPointOfTheRegion() throws {
    // Spread the nose region across two positions whose mean is the value
    // asserted. A `points[offset]` implementation passes the test above and
    // fails this one, which is the difference the old
    // `centroid(face.landmarks?.nose)` actually made.
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    var frame = Fixtures.face(box: box, nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
    let noseRange = FaceLandmarkLayout.offsets(FaceLandmarkLayout.regions76)["nose"]!
    for (n, i) in noseRange.enumerated() {
        frame.points[i] = Fixtures.point(CGPoint(x: n.isMultiple(of: 2) ? 0.46 : 0.54, y: 0.5))
    }
    let anchors = try #require(FaceAnchors.from(frame))
    // 9 points alternating 0.46/0.54 starting at 0.46: five at 0.46,
    // four at 0.54 -> mean 4.46/9 = 0.4955…
    #expect(abs(anchors.nose.x - 0.4955556) < 1e-4)
}

// MARK: - Face anchors, the degraded path
//
// `FaceFrame.points` is Apple's `allPoints` constellation and the proto
// deliberately declines to pin the per-region counts. So this plugin states
// a belief and checks it. These three tests are the check.

@Test func aPointCloudOfAnUnknownLengthFallsBackToTheBoundingBox() throws {
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    var frame = Fixtures.face(box: box, nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
    frame.points.removeLast()          // 75 points: no layout describes this
    let anchors = try #require(FaceAnchors.from(frame))

    #expect(anchors.source == .bounds)
    #expect(abs(anchors.nose.y - box.midY) < 1e-6)
    #expect(abs(anchors.mouth.y - (box.maxY - box.height * 0.2)) < 1e-6)
}

@Test func aFaceFrameWithNoPointsAtAllFallsBackToTheBoundingBox() throws {
    // What the provider publishes if it ever runs a face-RECTANGLE request
    // without landmarks. Bounds alone is a perfectly usable, if blunter,
    // detection input, and is exactly the fallback the pre-cutover
    // extractor used when `landmarks?.nose` came back nil.
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    let anchors = try #require(FaceAnchors.from(Fixtures.faceBoundsOnly(box: box)))
    #expect(anchors.source == .bounds)
    #expect(abs(anchors.nose.x - box.midX) < 1e-6)
}

@Test func aLayoutThatIndexesTheWrongRegionIsRejectedRatherThanTrusted() throws {
    // The dangerous failure this guard exists for: an offset table that is
    // the right LENGTH but points at the wrong regions does not crash — it
    // reports an eyebrow as the nose and the detector starts firing on
    // foreheads. Simulated here by putting the "nose" region up where an
    // eyebrow lives; the anchors must be refused and the box used instead.
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    var frame = Fixtures.face(box: box, nose: CGPoint(x: 0.5, y: 0.5), mouth: CGPoint(x: 0.5, y: 0.62))
    let noseRange = FaceLandmarkLayout.offsets(FaceLandmarkLayout.regions76)["nose"]!
    for i in noseRange { frame.points[i] = Fixtures.point(CGPoint(x: 0.45, y: 0.33)) }

    let anchors = try #require(FaceAnchors.from(frame))
    #expect(anchors.source == .bounds)
}

@Test func aNoseBelowTheMouthIsRejected() {
    // The other way a wrong table shows up: two regions swapped. Ordering
    // is the cheapest check that catches it and cannot be satisfied by any
    // real face.
    let box = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)
    #expect(FaceAnchors.plausible(nose: CGPoint(x: 0.5, y: 0.62),
                                  mouth: CGPoint(x: 0.5, y: 0.5),
                                  in: box) == false)
}

@Test func theEmptyNoFaceFrameIsNilAndNotAZeroSizedFace() {
    // A valid published message meaning "the model ran and saw nobody". If
    // this returned a degenerate zero-size box instead of nil, every
    // fingertip in the frame would sit "above the forehead" of a face at
    // the origin, and hair-pulling would fire on an empty room.
    #expect(FaceAnchors.from(Fixtures.noFace()) == nil)
}

@Test func theKnownLayoutIsInternallyConsistent() {
    // The offsets are derived from the counts, so the one thing that can be
    // wrong without being obvious is the counts not summing to the
    // constellation they claim to describe.
    let total = FaceLandmarkLayout.regions76.reduce(0) { $0 + $1.count }
    #expect(total == 76)
    #expect(FaceLandmarkLayout.forPointCount(76) != nil)
    #expect(FaceLandmarkLayout.forPointCount(65) == nil)
    let offsets = FaceLandmarkLayout.offsets(FaceLandmarkLayout.regions76)
    // Regions tile the array with no gap and no overlap.
    let covered = FaceLandmarkLayout.regions76.reduce(into: Set<Int>()) { set, region in
        set.formUnion(offsets[region.name]!)
    }
    #expect(covered.count == total)
    #expect(covered.max() == total - 1)
}

// MARK: - Fingertips

@Test func fingertipsComeFromTheFiveTipJointsInOrder() {
    let tips = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3),
                CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.5, y: 0.5)]
    let extracted = Fixtures.hands(fingertips: tips).fingertips
    #expect(extracted.count == 5)
    for (a, b) in zip(extracted, tips) {
        #expect(abs(a.x - b.x) < 1e-6)
        #expect(abs(a.y - b.y) < 1e-6)
    }
}

@Test func aLowConfidenceJointIsDroppedJustAsTheShippedExtractorDroppedIt() {
    var frame = Fixtures.hands(fingertips: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
    frame.hands[0].jointConfidence[8] = 0.3   // strictly-greater-than gate
    let extracted = frame.fingertips
    #expect(extracted.count == 1)
    #expect(abs(extracted[0].x - 0.1) < 1e-6)
}

@Test func anAbsentConfidenceArrayMeansUnknownNotZero() {
    // The proto is explicit: an EMPTY `joint_confidence` means the provider
    // does not report per-joint confidence. Reading it as zero would
    // discard every fingertip of every hand and silently kill detection
    // against any provider that omits the field.
    var frame = Fixtures.hands(fingertips: [CGPoint(x: 0.1, y: 0.1)])
    frame.hands[0].jointConfidence = []
    #expect(frame.fingertips.count == 5)
}

@Test func aWrongLengthConfidenceArrayIsIgnoredRatherThanIndexed() {
    // "Either empty or exactly as long as joints; never any other length" is
    // the provider's obligation, not something a consumer may assume — a
    // short array indexed at 20 is a crash, and a plugin does not get to
    // crash.
    var frame = Fixtures.hands(fingertips: [CGPoint(x: 0.1, y: 0.1)])
    frame.hands[0].jointConfidence = [0.9, 0.9]
    #expect(frame.fingertips.count == 5)
}

@Test func onlyTheHighestConfidenceHandIsRead() {
    // Two-handed detection is deliberately deferred (design §11): reading
    // both hands would double the fingertips fed to the detector and change
    // how readily it fires. `hands` is ordered by descending confidence, so
    // "the first" is "the best".
    var frame = Fixtures.hands(fingertips: [CGPoint(x: 0.1, y: 0.1)])
    let second = Fixtures.hands(fingertips: [CGPoint(x: 0.9, y: 0.9)]).hands[0]
    frame.hands.append(second)
    let extracted = frame.fingertips
    #expect(extracted.count == 1)
    #expect(abs(extracted[0].x - 0.1) < 1e-6)
}

@Test func theEmptyNoHandsFrameYieldsNoFingertips() {
    #expect(Fixtures.noHands().fingertips.isEmpty)
}

// MARK: - Segmentation bitmask
//
// These are the old HairMask tests, re-pointed at the packed wire format.
// The fixture packs the bits longhand and the production code unpacks them,
// so the two are genuinely separate implementations of the proto's stated
// layout rather than one formula agreeing with itself.

@Test func maskRowZeroIsTopInViewerSpace() {
    // 2 cols x 2 rows, only the top-left cell set.
    let mask = Fixtures.segmentation(cols: 2, rows: 2, cells: [true, false, false, false])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.25)) == true)   // top-left
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.75, y: 0.25)) == false)  // top-right
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.75)) == false)  // bottom-left
}

@Test func maskClampsAndRejectsOutOfRange() {
    let mask = Fixtures.segmentation(cols: 2, rows: 2, allPerson: true)
    #expect(mask.isPerson(atNormalized: CGPoint(x: -0.1, y: 0.5)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 1.1)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 1.0, y: 1.0)) == true)   // clamped edge
}

@Test func anEmptyMaskIsNeverPersonAndReportsNoGrid() {
    let mask = Fixtures.segmentation(cols: 0, rows: 0, cells: [])
    #expect(mask.hasGrid == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.5)) == false)
}

@Test func aTruncatedMaskIsRefusedRatherThanReadPastItsEnd() {
    // A provider bug (or a truncated payload) must not be a crash. The bit
    // index is checked against the actual byte count, not against w*h.
    var mask = Fixtures.segmentation(cols: 64, rows: 48, allPerson: true)
    mask.mask = Data([0xFF])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.02, y: 0.01)) == true)  // inside byte 0
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.9)) == false)   // past the end
}

@Test func aRealisticSixtyFourByFortyEightMaskRoundTrips() {
    // The shipping grid size, with one cell set well away from byte
    // boundaries — the case an off-by-one in the MSB-first shift gets wrong
    // while every 8-cell fixture still passes.
    let cols = 64, rows = 48
    var cells = [Bool](repeating: false, count: cols * rows)
    let row = 17, col = 43
    cells[row * cols + col] = true
    let mask = Fixtures.segmentation(cols: cols, rows: rows, cells: cells)
    let x = (CGFloat(col) + 0.5) / CGFloat(cols)
    let y = (CGFloat(row) + 0.5) / CGFloat(rows)
    #expect(mask.isPerson(atNormalized: CGPoint(x: x, y: y)) == true)
    #expect(mask.isPerson(atNormalized: CGPoint(x: x, y: y - 1.0 / CGFloat(rows))) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: x - 1.0 / CGFloat(cols), y: y)) == false)
}

// MARK: - VisionFrame

@Test func visionFrameTakesItsSeqFromWhicheverHeaderIsPresent() {
    let hands = Fixtures.hands(seq: 42, fingertips: [CGPoint(x: 0.5, y: 0.5)])
    #expect(VisionFrame(hands: hands).seq == 42)
    #expect(VisionFrame(face: Fixtures.noFace(seq: 7), hands: hands).seq == 7)
}

@Test func visionFrameDropsAGridlessSegmentationSoTheDetectorSeesNoMask() {
    let empty = Fixtures.segmentation(cols: 0, rows: 0, cells: [])
    let frame = VisionFrame(face: Fixtures.faceBoundsOnly(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)),
                            hands: Fixtures.noHands(),
                            segmentation: empty)
    #expect(frame.segmentation == nil)
}

// MARK: - Behaviour presentation (carried over from GeometryTests)

@Test func everyBehaviorHasNonEmptyPresentation() {
    for b in BFRBBehavior.allCases {
        #expect(!b.label.isEmpty)
        #expect(!b.nudge.isEmpty)
        #expect(!b.alertIcon.isEmpty)
        #expect(!b.defaultIconId.isEmpty)
    }
}

@Test func everyBehaviorNeedsAFaceAndHandsAndOnlyHairPullingNeedsSegmentation() {
    // The rule that makes `vision.request.v1` truthful rather than a
    // blanket "give me everything": a user who only wants nail-biting must
    // not pay for VNGeneratePersonSegmentationRequest.
    for b in BFRBBehavior.allCases {
        #expect(b.requiredVisionTopics.contains(.face))
        #expect(b.requiredVisionTopics.contains(.hands))
    }
    #expect(BFRBBehavior.hairPulling.requiredVisionTopics.contains(.segmentation))
    #expect(BFRBBehavior.nailBiting.requiredVisionTopics.contains(.segmentation) == false)
    #expect(BFRBBehavior.nosePicking.requiredVisionTopics.contains(.segmentation) == false)
}

@Test func topicRawValuesAreTheWireNames() {
    // A typo here is a subscription that silently never fires — the
    // manifest and this enum have to spell the topics identically, and
    // nothing but a literal can check that.
    #expect(VisionTopic.face.rawValue == "vision.face.v1")
    #expect(VisionTopic.hands.rawValue == "vision.hands.v1")
    #expect(VisionTopic.segmentation.rawValue == "vision.segmentation.v1")
    #expect(VisionRequest.topic == "vision.request.v1")
    #expect(VisionRequest.requester == "vibecheck")
}
