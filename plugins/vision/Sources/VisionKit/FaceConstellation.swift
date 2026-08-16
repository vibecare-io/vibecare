import CoreGraphics
import Foundation
import VCGeometry
import VCKStubs

/// One face-landmark region, reduced to the two things building the published
/// point array needs.
///
/// It exists so the concatenation below can be tested without a camera and
/// without fabricating a `VNFaceLandmarks2D`, which has no public initializer.
/// `VNFaceLandmarkRegion2D` already provides both members, so conforming it is
/// an empty extension in `AppleVisionAnalyzer`.
public protocol FaceRegionPoints {
    var pointCount: Int { get }
    func pointsInImage(imageSize: CGSize) -> [CGPoint]
}

/// Builds `FaceFrame.points` and the layout that indexes it **from the same
/// source**, so the two cannot disagree.
///
/// ## Why this is not `landmarks.allPoints`
///
/// It used to be. The points came from `allPoints` and the layout came from
/// summing the twelve regions' `pointCount`, which assumed `allPoints` is
/// exactly those regions concatenated in order. Apple documents neither the
/// per-region counts nor that concatenation, and measured on macOS 26 it is
/// simply false:
///
///     face regions sum to 87 but allPoints published 76
///     (counts=[17, 6, 6, 6, 6, 8, 6, 10, 14, 6, 1, 1])
///
/// The layout guard then correctly refused to emit an offset table — an
/// 87-point table indexing a 76-point array reports an eyebrow as an eye, and
/// an eye aspect ratio computed from eyebrow points is a plausible-looking
/// number that is wrong — so every face-derived signal (`ear_l`, `ear_r`,
/// `yaw`, `pitch`, `roll`) stayed absent on every frame. Consumers behaved
/// correctly throughout: blink-jump paused itself and said so. The defect was
/// upstream of all of them.
///
/// Concatenating the regions ourselves removes the assumption rather than
/// correcting it. `FaceRegion.allCases` order is what the wire contract pins,
/// and now it is also what the array literally is.
public enum FaceConstellation {
    /// - Parameters:
    ///   - regions: one entry per `FaceRegion`, in `allCases` order. `nil` for
    ///     a region Vision did not return — pupils routinely are not.
    ///   - mirrored: as the capture connection reported it **this frame**.
    /// - Returns: the points in viewer space, and the layout describing them.
    ///   `layout` is `nil` only when there are no points at all, which means
    ///   "no landmarks" and must leave every derived signal absent.
    public static func build(regions: [FaceRegionPoints?],
                             mirrored: Bool) -> (points: [VCTPoint], layout: FaceLandmarkLayout?) {
        precondition(regions.count == FaceRegion.allCases.count,
                     "regions must be one per FaceRegion, in allCases order")

        var points: [VCTPoint] = []
        var counts: [Int] = []
        counts.reserveCapacity(regions.count)

        for region in regions {
            guard let region, region.pointCount > 0 else {
                counts.append(0)
                continue
            }
            // `pointsInImage(imageSize: 1x1)` yields whole-image normalized
            // Vision-space coordinates. A region's own `normalizedPoints` are
            // relative to the face's bounding box and would land the whole
            // constellation inside a tiny square in the corner.
            let mapped = region.pointsInImage(imageSize: CGSize(width: 1, height: 1))
                .map { ViewerSpaceMapping.protoPoint($0, mirrored: mirrored) }
            points.append(contentsOf: mapped)
            // The region's own count, not `mapped.count`, would be the same
            // number — but taking it from what was actually appended is what
            // makes agreement structural rather than a claim.
            counts.append(mapped.count)
        }

        guard !points.isEmpty else { return ([], nil) }
        return (points, FaceLandmarkLayout(pointCounts: counts))
    }
}
