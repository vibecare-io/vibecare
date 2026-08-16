import Foundation
import Testing
import VCKStubs
@testable import VCGeometry

// The fixture eye is a six-point lens: corners at ±halfWidth, upper and lower
// lids at ±halfHeight. Its width is 2*halfWidth and its perpendicular extent
// 2*halfHeight, so the ratio is exactly halfHeight/halfWidth — computed by
// hand, not by running the implementation.

@Test func eyeAspectRatioOfAWideOpenEye() throws {
    let contour = FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02)
    let ear = try #require(EyeAspectRatio.value(of: contour, aspect: .square))
    #expect(isClose(ear, 0.4, tolerance: lengthTolerance))
}

@Test func eyeAspectRatioOfANarrowEye() throws {
    let contour = FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.005)
    let ear = try #require(EyeAspectRatio.value(of: contour, aspect: .square))
    #expect(isClose(ear, 0.1, tolerance: lengthTolerance))
}

@Test func aFullyClosedEyeIsZeroAndPresent() throws {
    // THE distinction this whole tier turns on. A closed eye is a real
    // measurement of 0.0; a face model that is not running is ABSENT. If the
    // two were ever collapsed, a consumer would see a permanently closed eye
    // whenever nobody asked for faces.
    let flat = (0 ..< 6).map { vp(0.40 + Float($0) * 0.01, 0.40) }
    let ear = try #require(EyeAspectRatio.value(of: flat, aspect: .square))
    #expect(ear == 0)
}

@Test func eyeAspectRatioIsUnchangedByHeadRoll() throws {
    // The corner axis rotates with the eye, so a tilted head must not read as a
    // narrowed one. Without this, "blinked" would fire every time the user
    // leaned on one elbow.
    let upright = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02),
        aspect: .square))
    for roll in [Float(15), 40, -30, 75] {
        let tilted = try #require(EyeAspectRatio.value(
            of: FaceFixture.eyeContour(centre: vp(0.42, 0.40),
                                       halfWidth: 0.05,
                                       halfHeight: 0.02,
                                       rollDegrees: roll),
            aspect: .square))
        #expect(isClose(tilted, upright, tolerance: 1e-4))
    }
}

@Test func eyeAspectRatioIsUnchangedByHowCloseTheUserSits() throws {
    let near = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.5, 0.4), halfWidth: 0.10, halfHeight: 0.04),
        aspect: .square))
    let far = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.2, 0.7), halfWidth: 0.025, halfHeight: 0.01),
        aspect: .square))
    #expect(isClose(near, far, tolerance: lengthTolerance))
}

@Test func eyeAspectRatioIsUnchangedByTheCamerasAspectRatio() throws {
    // The same physical eye, on a 16:9 frame and on a square one. Its
    // normalized x coordinates differ; its ratio must not, or a threshold
    // tuned on one webcam is wrong on the next.
    let wide = Aspect(frameWidth: 1280, frameHeight: 720)
    let onWide = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02, aspect: wide),
        aspect: wide))
    let onSquare = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02),
        aspect: .square))
    #expect(isClose(onWide, onSquare, tolerance: 1e-5))

    // And the correction is doing real work: reading the SAME normalized
    // coordinates as if the frame were square gives a visibly different answer.
    let uncorrected = try #require(EyeAspectRatio.value(
        of: FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02, aspect: wide),
        aspect: .square))
    #expect(abs(uncorrected - onSquare) > 0.1)
}

@Test func eyeAspectRatioNeedsFourPointsToHaveAHeight() {
    // With three points, two are corners and the third sits on one side of the
    // axis only. The extent would be halved and a wide-open eye would report
    // half-closed, so the honest answer is to refuse.
    let three = [vp(0.40, 0.40), vp(0.45, 0.38), vp(0.50, 0.40)]
    #expect(EyeAspectRatio.value(of: three, aspect: .square) == nil)
    #expect(EyeAspectRatio.value(of: [VCTPoint](), aspect: .square) == nil)
}

@Test func eyeAspectRatioIsNilWhenEveryPointCollapsedOntoOne() {
    // A real failure mode: a detector losing the eye pins every point to one
    // place. There is no width to divide by, so there is no ratio — and
    // reporting 0 would be indistinguishable from a shut eye.
    let collapsed = [VCTPoint](repeating: vp(0.42, 0.40), count: 6)
    #expect(EyeAspectRatio.value(of: collapsed, aspect: .square) == nil)
}

@Test func eyeAspectRatioReadsTheRegionForTheRequestedEye() throws {
    // ear_l is the SUBJECT's left eye. Getting this backwards would be
    // invisible on a symmetric face and wrong on every blink.
    let openContour = FaceFixture.eyeContour(centre: vp(0.42, 0.40), halfWidth: 0.05, halfHeight: 0.02)
    let closedContour = FaceFixture.eyeContour(centre: vp(0.58, 0.40), halfWidth: 0.05, halfHeight: 0.0)
    let frame = FaceFixture.frame(leftEyeContour: openContour,
                                  rightEyeContour: closedContour,
                                  leftPupil: vp(0.42, 0.40),
                                  rightPupil: vp(0.58, 0.40),
                                  nose: vp(0.5, 0.5),
                                  mouth: vp(0.5, 0.58))
    let landmarks = try #require(FaceLandmarks(frame: frame, layout: FaceFixture.layout))
    let left = try #require(EyeAspectRatio.value(of: landmarks, eye: .left, aspect: .square))
    let right = try #require(EyeAspectRatio.value(of: landmarks, eye: .right, aspect: .square))
    #expect(isClose(left, 0.4, tolerance: lengthTolerance))
    #expect(right == 0)
}
