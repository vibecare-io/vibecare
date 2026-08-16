import CoreGraphics
import Foundation
import Testing
import VCGeometry
@testable import VisionKit

// The published face point array and the layout that indexes it must agree,
// or every face-derived signal is absent.
//
// They used to be built from two different sources: the points from
// `VNFaceLandmarks2D.allPoints`, the layout from summing the twelve regions.
// That assumed `allPoints` IS the concatenation of those regions, which Apple
// does not document and which is false in practice — measured on macOS 26,
// the regions sum to 87 while `allPoints` publishes 76. The guard then
// (correctly) refused to build an offset table, and `ear_l`, `ear_r`, `yaw`,
// `pitch` and `roll` were absent on every frame forever, with the only
// evidence a single log line.
//
// So the array is now built FROM the regions, in `FaceRegion.allCases` order.
// These tests pin that the two can no longer disagree.

/// A region with known contents, so a point can be traced back to the region
/// it came from. Stands in for `VNFaceLandmarkRegion2D` — fabricating a real
/// one needs a camera and a face.
private struct FakeRegion: FaceRegionPoints {
    let points: [CGPoint]
    var pointCount: Int { points.count }
    func pointsInImage(imageSize: CGSize) -> [CGPoint] { points }
}

/// `n` points whose x encodes the region and whose y encodes the position
/// within it, so any mis-slicing is visible in the value itself.
private func region(_ tag: Int, _ n: Int) -> FakeRegion {
    FakeRegion(points: (0 ..< n).map { CGPoint(x: Double(tag) / 100.0, y: Double($0) / 100.0) })
}

@Test func pointsAndLayoutAreBuiltFromTheSameRegionsSoTheyCannotDisagree() throws {
    // The exact counts measured from the shipped constellation, which sum to
    // 87 — the number that did not match `allPoints`.
    let counts = [17, 6, 6, 6, 6, 8, 6, 10, 14, 6, 1, 1]
    let regions: [FaceRegionPoints?] = counts.enumerated().map { region($0.offset, $0.element) }

    // mirrored: true means the connection already mirrored the frame, so x
    // passes through untouched and a point still identifies its region.
    let built = FaceConstellation.build(regions: regions, mirrored: true)

    let layout = try #require(built.layout, "a complete region set must produce a layout")
    #expect(built.points.count == 87)
    #expect(layout.totalPointCount == built.points.count,
            "the layout must describe exactly the array that was published")
    #expect(layout.pointCounts == counts)
}

@Test func eachRegionsRangeSelectsThatRegionsOwnPoints() throws {
    let counts = [17, 6, 6, 6, 6, 8, 6, 10, 14, 6, 1, 1]
    let regions: [FaceRegionPoints?] = counts.enumerated().map { region($0.offset, $0.element) }

    // mirrored: true means the connection already mirrored the frame, so x
    // passes through untouched and a point still identifies its region.
    let built = FaceConstellation.build(regions: regions, mirrored: true)
    let layout = try #require(built.layout)

    // The whole point of the layout: ask for the left eye, get the left eye.
    // Reporting an eyebrow as an eye is the failure this replaces, and it is
    // silent — an EAR computed from eyebrow points is a plausible number.
    for face in FaceRegion.allCases {
        let range = layout.range(of: face)
        #expect(range.count == counts[face.rawValue])
        for index in range {
            #expect(abs(Double(built.points[index].x) - Double(face.rawValue) / 100.0) < 0.0001,
                    "\(face) range selected a point belonging to another region")
        }
    }
}

@Test func anAbsentRegionTakesNoSpaceAndDoesNotShiftTheOnesAfterIt() throws {
    // Pupils are routinely absent. That must narrow their range to nothing,
    // not slide every later region's offset — which would be the silent
    // mis-indexing all over again.
    var regions: [FaceRegionPoints?] = FaceRegion.allCases.map { region($0.rawValue, 4) }
    regions[FaceRegion.leftPupil.rawValue] = nil
    regions[FaceRegion.rightPupil.rawValue] = nil

    // mirrored: true means the connection already mirrored the frame, so x
    // passes through untouched and a point still identifies its region.
    let built = FaceConstellation.build(regions: regions, mirrored: true)
    let layout = try #require(built.layout)

    #expect(built.points.count == 4 * (FaceRegion.allCases.count - 2))
    #expect(layout.range(of: .leftPupil).isEmpty)
    #expect(layout.range(of: .rightPupil).isEmpty)
    // outerLips comes before the pupils, so its offset is untouched.
    #expect(layout.range(of: .outerLips).count == 4)
    for index in layout.range(of: .outerLips) {
        #expect(abs(Double(built.points[index].x) - Double(FaceRegion.outerLips.rawValue) / 100.0) < 0.0001)
    }
}

@Test func noRegionsAtAllMeansNoLayoutRatherThanAnEmptyOne() {
    let built = FaceConstellation.build(regions: FaceRegion.allCases.map { _ in nil }, mirrored: true)
    #expect(built.points.isEmpty)
    #expect(built.layout == nil,
            "a face with no landmarks must leave signals absent, not report a zero-length constellation")
}

@Test func mirroringIsAppliedToThePublishedPoints() throws {
    let regions: [FaceRegionPoints?] = FaceRegion.allCases.map { _ in
        FakeRegion(points: [CGPoint(x: 0.25, y: 0.75)])
    }

    // `mirrored` reports what the CONNECTION already did, so `false` is the
    // case where the provider must flip x itself — and false is what the
    // built-in Mac camera actually reports, since it never auto-mirrors.
    let connectionMirrored = FaceConstellation.build(regions: regions, mirrored: true)
    let providerMustMirror = FaceConstellation.build(regions: regions, mirrored: false)

    #expect(abs(connectionMirrored.points[0].x - 0.25) < 0.0001)
    #expect(abs(providerMustMirror.points[0].x - 0.75) < 0.0001)
    // y is flipped either way, because Vision is y-up and viewer space is
    // y-down. Consumers never mirror, so both happen here.
    #expect(abs(connectionMirrored.points[0].y - 0.25) < 0.0001)
    #expect(abs(providerMustMirror.points[0].y - 0.25) < 0.0001)
}
