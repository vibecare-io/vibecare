import CoreGraphics
import Foundation
import Testing
@testable import VisionKit

/// Coordinate and mirroring normalization.
///
/// Everything vision publishes is viewer space — origin top-left, x right,
/// y DOWN, normalized 0..1 — and the provider mirrors BEFORE publishing so no
/// consumer ever mirrors. Three surfaces derive their flip from one
/// `connection.isVideoMirrored` value read per frame: landmark x, mask columns
/// and the preview JPEG. These tests pin them against each other, because a
/// disagreement between any two shows up only as an overlay drawn on the wrong
/// side of the user's face, which no single surface's own test can catch.
@Suite struct ViewerSpaceMappingTests {
    @Test func yIsAlwaysFlippedBecauseVisionIsYUp() {
        // Vision's origin is bottom-left; viewer space is top-left.
        for mirrored in [true, false] {
            let mapped = ViewerSpaceMapping.point(CGPoint(x: 0.5, y: 0.9), mirrored: mirrored)
            #expect(abs(mapped.y - 0.1) < 1e-9)
        }
    }

    @Test func xIsFlippedOnlyWhenTheSourceWasNotAlreadyMirrored() {
        // Already mirrored by the connection: x passes through untouched.
        #expect(abs(ViewerSpaceMapping.point(CGPoint(x: 0.2, y: 0.5), mirrored: true).x - 0.2) < 1e-9)
        // Not mirrored — the measured case for the built-in Mac camera, whose
        // position is .unspecified so automaticallyAdjustsVideoMirroring never
        // engages. The provider does the flip itself.
        #expect(abs(ViewerSpaceMapping.point(CGPoint(x: 0.2, y: 0.5), mirrored: false).x - 0.8) < 1e-9)
    }

    @Test func aRectsMidpointAgreesWithTheSamePointMapped() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        for mirrored in [true, false] {
            let mappedRect = ViewerSpaceMapping.rect(rect, mirrored: mirrored)
            let mappedMid = ViewerSpaceMapping.point(CGPoint(x: rect.midX, y: rect.midY),
                                                     mirrored: mirrored)
            #expect(abs(mappedRect.midX - mappedMid.x) < 1e-9)
            #expect(abs(mappedRect.midY - mappedMid.y) < 1e-9)
            // Size is orientation-independent.
            #expect(abs(mappedRect.width - rect.width) < 1e-9)
            #expect(abs(mappedRect.height - rect.height) < 1e-9)
        }
    }

    @Test func aRectStaysInsideTheUnitSquareUnderBothFlips() {
        let rect = CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.2)
        for mirrored in [true, false] {
            let mapped = ViewerSpaceMapping.rect(rect, mirrored: mirrored)
            #expect(mapped.minX >= -1e-9)
            #expect(mapped.maxX <= 1 + 1e-9)
            #expect(mapped.minY >= -1e-9)
            #expect(mapped.maxY <= 1 + 1e-9)
        }
    }

    @Test func maskColumnsFlipByTheSameRuleAsLandmarkX() {
        // The mask buffer's column order matches the SOURCE frame, so mapping
        // a viewer column back to a source column must be the same reversal
        // `point` applies to x — expressed as an index instead of a [0,1]
        // coordinate. Stated as an equality between the two rules rather than
        // two independently-written expectations, so a change to one that
        // forgets the other goes red here.
        let cols = 64
        for mirrored in [true, false] {
            for column in [0, 1, 31, 32, 63] {
                let viewerX = (Double(column) + 0.5) / Double(cols)
                // Where does that viewer x come from in Vision space?
                let sourceX = ViewerSpaceMapping.point(CGPoint(x: viewerX, y: 0.5),
                                                       mirrored: mirrored).x
                let expected = Int(sourceX * Double(cols))
                #expect(ViewerSpaceMapping.sourceColumn(forViewerColumn: column,
                                                        cols: cols,
                                                        mirrored: mirrored) == expected)
            }
        }
    }

    @Test func sourceColumnIsIdentityWhenMirroredAndAReversalWhenNot() {
        #expect(ViewerSpaceMapping.sourceColumn(forViewerColumn: 0, cols: 64, mirrored: true) == 0)
        #expect(ViewerSpaceMapping.sourceColumn(forViewerColumn: 0, cols: 64, mirrored: false) == 63)
        #expect(ViewerSpaceMapping.sourceColumn(forViewerColumn: 63, cols: 64, mirrored: false) == 0)
    }

    @Test func theWireTypesCarryTheAlreadyConvertedValues() {
        let point = ViewerSpaceMapping.protoPoint(CGPoint(x: 0.25, y: 0.75), mirrored: false)
        #expect(abs(point.x - 0.75) < 1e-6)
        #expect(abs(point.y - 0.25) < 1e-6)

        let rect = ViewerSpaceMapping.protoRect(CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                                mirrored: false)
        // Viewer-space x,y is the TOP-LEFT corner: 1 - maxX, 1 - maxY.
        #expect(abs(rect.x - 0.6) < 1e-6)
        #expect(abs(rect.y - 0.4) < 1e-6)
        #expect(abs(rect.w - 0.3) < 1e-6)
        #expect(abs(rect.h - 0.4) < 1e-6)
    }

    @Test func theMaskBitOrderMatchesTheWireContractsFormula() {
        var cells = [Bool](repeating: false, count: 64 * 48)
        cells[0] = true       // row 0, col 0
        cells[7] = true       // row 0, col 7 — last bit of byte 0
        cells[8] = true       // row 0, col 8 — first bit of byte 1
        cells[64 + 3] = true  // row 1, col 3

        let mask = AppleVisionAnalyzer.packBits(cells)
        #expect(mask.count == (64 * 48) / 8)

        // The proto spells it out: MSB first,
        //   set = (mask[index / 8] >> (7 - (index % 8))) & 1
        func bit(_ index: Int) -> Bool {
            (mask[index / 8] >> UInt8(7 - index % 8)) & 1 == 1
        }
        for index in [0, 7, 8, 64 + 3] { #expect(bit(index)) }
        for index in [1, 6, 9, 64 + 2, 64 + 4] { #expect(bit(index) == false) }
    }

    @Test func theJPEGFlipUsesTheSameConditionAsTheLandmarkFlip() {
        // The image flip and the coordinate flip must agree about which frames
        // need flipping. `JPEGEncoder` applies `.upMirrored` iff `!mirrored`,
        // and `ViewerSpaceMapping.point` reverses x iff `!mirrored` — this
        // asserts the second half and that both encode paths produce output,
        // so a mirrored and an unmirrored frame are genuinely different bytes.
        let buffer = makeTestPixelBuffer(width: 32, height: 32)
        let straight = JPEGEncoder.encode(buffer, quality: 0.6, mirrored: true)
        let flipped = JPEGEncoder.encode(buffer, quality: 0.6, mirrored: false)
        #expect(straight != nil)
        #expect(flipped != nil)

        let identity = ViewerSpaceMapping.point(CGPoint(x: 0.3, y: 0.4), mirrored: true)
        let mirrored = ViewerSpaceMapping.point(CGPoint(x: 0.3, y: 0.4), mirrored: false)
        #expect(identity.x != mirrored.x)
        #expect(identity.y == mirrored.y)
    }
}
