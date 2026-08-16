import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

@Test func layoutRejectsAWrongLengthCountArray() {
    // A layout built from anything other than the regions actually published
    // would slide every index along by a few points, and an eyebrow would be
    // reported as an eye without a single assertion firing.
    #expect(FaceLandmarkLayout(pointCounts: [11, 6, 6]) == nil)
}

@Test func layoutRejectsNegativeCounts() {
    var counts = [Int](repeating: 1, count: FaceRegion.allCases.count)
    counts[FaceRegion.nose.rawValue] = -1
    #expect(FaceLandmarkLayout(pointCounts: counts) == nil)
}

@Test func layoutRangesAreContiguousAndInDeclaredOrder() {
    let layout = FaceFixture.layout
    var expectedStart = 0
    for region in FaceRegion.allCases {
        let range = layout.range(of: region)
        #expect(range.lowerBound == expectedStart)
        #expect(range.count == layout.pointCount(of: region))
        expectedStart = range.upperBound
    }
    #expect(expectedStart == layout.totalPointCount)
}

@Test func layoutToleratesRegionsVisionDidNotReturn() throws {
    // Pupils are routinely absent. A zero-length region is an empty range, not
    // an error, and everything after it still lands in the right place.
    var counts = [Int](repeating: 2, count: FaceRegion.allCases.count)
    counts[FaceRegion.leftPupil.rawValue] = 0
    counts[FaceRegion.rightPupil.rawValue] = 0
    let layout = try #require(FaceLandmarkLayout(pointCounts: counts))
    #expect(layout.range(of: .leftPupil).isEmpty)
    #expect(layout.totalPointCount == 20)
}

@Test func faceLandmarksRejectAPointCountThatDisagreesWithTheLayout() {
    var frame = VCTFaceFrame()
    frame.points = Array(repeating: vp(0.5, 0.5), count: FaceFixture.layout.totalPointCount - 1)
    #expect(FaceLandmarks(frame: frame, layout: FaceFixture.layout) == nil)
}

@Test func faceLandmarksRejectAnEmptyFrame() {
    // An empty FaceFrame is a VALID published message meaning "the model ran
    // and saw no face". It must not be read as a face at the origin, and it
    // must leave every face-derived signal absent rather than zero.
    var frame = VCTFaceFrame()
    frame.header = vheader()
    #expect(frame.points.isEmpty)
    #expect(FaceLandmarks(frame: frame, layout: FaceFixture.layout) == nil)
}

@Test func faceLandmarksSliceEachRegionAtItsDeclaredOffset() throws {
    let head = SyntheticHead()
    let projection = head.project(yaw: 0, pitch: 0, roll: 0)
    let frame = head.faceFrame(yaw: 0, pitch: 0, roll: 0)
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: FaceFixture.layout))

    #expect(landmarks.points(of: .leftEye).count == FaceFixture.eyeContourPoints)
    #expect(landmarks.points(of: .leftPupil).count == 1)

    // The nose and lip regions were filled with a single repeated point, so
    // their centroids are exactly those points — a bug that read the wrong
    // region would land on the junk filler at (0.99, 0.01) instead.
    let nose = try #require(landmarks.nose)
    #expect(isClose(nose.x, projection.nose.x, tolerance: lengthTolerance))
    #expect(isClose(nose.y, projection.nose.y, tolerance: lengthTolerance))
    let mouth = try #require(landmarks.mouth)
    #expect(isClose(mouth.x, projection.mouth.x, tolerance: lengthTolerance))
    #expect(isClose(mouth.y, projection.mouth.y, tolerance: lengthTolerance))
}

@Test func eyeCentrePrefersThePupilOverTheContourCentroid() throws {
    // A single pupil point is steadier than the mean of a contour that is
    // half-closed, so it wins when the constellation carried one.
    let contour = FaceFixture.eyeContour(centre: vp(0.40, 0.40), halfWidth: 0.03, halfHeight: 0.01)
    let frame = FaceFixture.frame(leftEyeContour: contour,
                                  rightEyeContour: contour,
                                  leftPupil: vp(0.11, 0.22),
                                  rightPupil: vp(0.33, 0.44),
                                  nose: vp(0.5, 0.5),
                                  mouth: vp(0.5, 0.6))
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: FaceFixture.layout))
    let left = try #require(landmarks.eyeCentre(.left))
    let right = try #require(landmarks.eyeCentre(.right))
    #expect(isClose(left.x, 0.11, tolerance: lengthTolerance))
    #expect(isClose(right.y, 0.44, tolerance: lengthTolerance))
}

@Test func eyeCentreFallsBackToTheContourWhenNoPupilWasPublished() throws {
    var counts = FaceRegion.allCases.map { FaceFixture.layout.pointCount(of: $0) }
    counts[FaceRegion.leftPupil.rawValue] = 0
    counts[FaceRegion.rightPupil.rawValue] = 0
    let layout = try #require(FaceLandmarkLayout(pointCounts: counts))

    // A contour centred on (0.40, 0.40) has that centroid by symmetry.
    let contour = FaceFixture.eyeContour(centre: vp(0.40, 0.40), halfWidth: 0.03, halfHeight: 0.012)
    var points: [VCTPoint] = []
    for region in FaceRegion.allCases {
        switch region {
        case .leftEye, .rightEye: points += contour
        default: points += Array(repeating: vp(0.99, 0.01), count: layout.pointCount(of: region))
        }
    }
    var frame = VCTFaceFrame()
    frame.points = points
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: layout))
    let centre = try #require(landmarks.eyeCentre(.left))
    #expect(isClose(centre.x, 0.40, tolerance: lengthTolerance))
    #expect(isClose(centre.y, 0.40, tolerance: lengthTolerance))
}

@Test func aZeroAreaBoundingBoxCannotPoisonAnySignal() throws {
    // Nothing in VCGeometry reads FaceFrame.bounds. A detector that publishes a
    // degenerate box still produces valid eye and pose readings, and this is
    // the assertion that keeps it that way.
    let head = SyntheticHead()
    var frame = head.faceFrame(yaw: 12, pitch: -6, roll: 4)
    frame.bounds = vrect(0.5, 0.5, 0, 0)
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: FaceFixture.layout))
    #expect(landmarks.bounds.w == 0)
    #expect(EyeAspectRatio.value(of: landmarks, eye: .left, aspect: .square) != nil)
    #expect(HeadPoseEstimator.estimate(face: landmarks, aspect: .square) != nil)
}

@Test func centroidOfAnEmptyRegionIsNil() {
    #expect(FaceLandmarks.centroid(of: [VCTPoint]()) == nil)
}
