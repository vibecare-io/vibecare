import Testing
import CoreVideo
import CoreGraphics
import Foundation
import AppKit
import VCPluginSDK
@testable import VibeCheckKit

// MARK: - Fixtures

private func solidBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

/// A BGRA buffer with a bright vertical stripe filling the LEFT QUARTER of
/// the frame and black everywhere else — a marker sitting at a known raw
/// pixel-buffer x position, uniform down every row so sampling at any y is
/// equally valid.
private func stripedBuffer(width: Int = 64, height: Int = 48) -> CVPixelBuffer {
    let buffer = solidBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let stripeEnd = width / 4
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let bright: UInt8 = x < stripeEnd ? 255 : 0
            base[offset] = bright      // B
            base[offset + 1] = bright  // G
            base[offset + 2] = bright  // R
            base[offset + 3] = 255     // A
        }
    }
    return buffer
}

/// Decodes JPEG bytes and reads the red channel at normalized x (0 = left
/// edge of the image, 1 = right edge), sampled at the vertical midpoint —
/// the stripe fixture above is uniform down every row, so y never matters.
private func brightness(ofJPEG data: Data, atNormalizedX nx: CGFloat) -> UInt8 {
    let rep = NSBitmapImageRep(data: data)!
    let x = min(rep.pixelsWide - 1, max(0, Int(nx * CGFloat(rep.pixelsWide - 1))))
    let y = rep.pixelsHigh / 2
    let color = rep.colorAt(x: x, y: y)!
    return UInt8((color.redComponent * 255).rounded())
}

// MARK: - JPEGEncoder: baseline (brief Step 1)

@Test func encodesABufferToJPEGBytes() throws {
    let data = JPEGEncoder.encode(solidBuffer(width: 64, height: 48), quality: 0.6, mirrored: true)
    let jpeg = try #require(data)
    #expect(jpeg.count > 0)
    // JPEG SOI marker.
    #expect(jpeg[0] == 0xFF && jpeg[1] == 0xD8)
}

// MARK: - JPEGEncoder: THE critical invariant (ruling M1)
//
// `LandmarkFrame.mirrored` is the single source of truth both the landmark
// flip (`ViewerSpace.point`/`.rect`, exercised by every real point/rect
// `VisionLandmarkExtractor` emits) and this JPEG flip must derive from. A
// test that checks each side in isolation — "does the image flip when
// mirrored is false", "does ViewerSpace flip x when mirrored is false" —
// can pass even if a future edit changes one rule and not the other, since
// nothing ties the two assertions' expected values together. This test
// pins them together directly: it builds a buffer with a marker at a KNOWN
// raw x, asks `ViewerSpace.point` — the landmark side's own, real
// conversion, not a re-derived copy of its formula — where that raw x
// lands in viewer space for a given `mirrored`, and then asserts the
// ACTUAL decoded JPEG is bright at that same viewer-space position (and
// dark at the mirror-image opposite). If `JPEGEncoder`'s flip condition
// and `ViewerSpace`'s ever disagree, this fails for exactly one of the two
// `mirrored` values below.
@Test(arguments: [true, false])
func imageFlipAgreesWithTheLandmarkFlipForTheSameMirroredFlag(mirrored: Bool) throws {
    let buffer = stripedBuffer()
    // The stripe fixture occupies raw x in [0, 0.25); its center.
    let rawMarkerX: CGFloat = 0.125

    // The landmark side's own answer for where this raw x lands in viewer
    // space — the exact function `VisionLandmarkExtractor` calls for every
    // point/rect it emits (see Geometry.swift).
    let expectedViewerX = ViewerSpace.point(CGPoint(x: rawMarkerX, y: 0.5), mirrored: mirrored).x

    let jpeg = try #require(JPEGEncoder.encode(buffer, quality: 0.9, mirrored: mirrored))
    let brightAtExpected = brightness(ofJPEG: jpeg, atNormalizedX: expectedViewerX)
    let brightAtOpposite = brightness(ofJPEG: jpeg, atNormalizedX: 1 - expectedViewerX)

    #expect(brightAtExpected > 200)
    #expect(brightAtOpposite < 50)
}

// MARK: - PreviewStream.multipartChunk (brief Step 1)

@Test func multipartFrameCarriesBoundaryAndLength() {
    let payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let chunk = PreviewStream.multipartChunk(payload, boundary: "vcframe")
    let text = String(decoding: chunk, as: UTF8.self)
    #expect(text.hasPrefix("--vcframe\r\n"))
    #expect(text.contains("Content-Type: image/jpeg\r\n"))
    #expect(text.contains("Content-Length: 4\r\n"))
}

// MARK: - PreviewStream: attach/publish orchestration
//
// `FakeWriter` is a minimal `VCResponseWriter` double so these exercise the
// actor's real attach/publish/drop logic instead of only the pure framing
// helper above.

private enum FakeWriterError: Error { case boom }

private actor FakeWriter: VCResponseWriter {
    private(set) var headWritten = false
    /// Captured, not discarded — a test asserting only `headWritten` cannot
    /// tell a correct multipart head apart from any other 200. See
    /// `attachSendsTheMultipartHead`, which reads these.
    private(set) var headStatus: Int?
    private(set) var headHeaders: [String: String] = [:]
    private(set) var writes: [Data] = []
    /// Counts every `write` call, including ones that go on to throw — the
    /// only way a test can tell "never called again after removal" apart
    /// from "called again but happened to throw".
    private(set) var writeAttempts = 0
    var shouldThrowOnWriteHead = false
    var shouldThrowOnWrite = false

    func writeHead(status: Int, headers: [String: String]) async throws {
        if shouldThrowOnWriteHead { throw FakeWriterError.boom }
        headWritten = true
        headStatus = status
        headHeaders = headers
    }

    func write(_ chunk: Data) async throws {
        writeAttempts += 1
        if shouldThrowOnWrite { throw FakeWriterError.boom }
        writes.append(chunk)
    }

    func finish() async throws {}

    func setShouldThrowOnWrite(_ value: Bool) { shouldThrowOnWrite = value }
    func setShouldThrowOnWriteHead(_ value: Bool) { shouldThrowOnWriteHead = value }
}

@Test func attachSendsTheMultipartHead() async {
    let stream = PreviewStream()
    let writer = FakeWriter()
    await stream.attach(writer)
    #expect(await writer.headWritten)
    #expect(await writer.headStatus == 200)
    let headers = await writer.headHeaders
    #expect(headers["Content-Type"] == "multipart/x-mixed-replace; boundary=vcframe")
    #expect(headers["Cache-Control"] == "no-store")
    #expect(await stream.writerCount == 1)
}

@Test func attachDoesNotRegisterAWriterWhoseHeadFails() async {
    let stream = PreviewStream()
    let writer = FakeWriter()
    await writer.setShouldThrowOnWriteHead(true)
    await stream.attach(writer)
    #expect(await stream.writerCount == 0)
}

@Test func dropsAWriterWhoseWriteThrowsWithoutDisturbingOthers() async throws {
    let stream = PreviewStream()
    let good = FakeWriter()
    let bad = FakeWriter()
    await bad.setShouldThrowOnWrite(true)
    await stream.attach(good)
    await stream.attach(bad)
    #expect(await stream.writerCount == 2)

    await stream.publish(stripedBuffer(), mirrored: true)

    #expect(await good.writes.count == 1)
    #expect(await bad.writeAttempts == 1)
    // The failing writer is gone; the good one is untouched.
    #expect(await stream.writerCount == 1)

    // Nothing green above proves `publish` actually emitted a
    // `multipartChunk`-framed JPEG rather than something else — inspect
    // the bytes `good` actually received.
    let firstWrite = try #require(await good.writes.first)
    #expect(firstWrite.starts(with: Data("--vcframe\r\n".utf8)))
    #expect(firstWrite.range(of: Data([0xFF, 0xD8])) != nil)   // JPEG SOI, somewhere in the body
}

// MARK: - PreviewStream: idles when nobody is attached
//
// `publish` returns before touching `JPEGEncoder` at all when `writers` is
// empty — but no fast, deterministic test can observe "no CPU work
// happened" from the outside, since `JPEGEncoder` is a stateless `enum`,
// not an injectable dependency. `framesEncoded` is the cheap seam that
// closes that gap without changing the encoder's shape: it counts only the
// attempts that got PAST the idle guard, so "stays at 0 with zero writers
// attached" is a real assertion about the guard firing, not a restatement
// of "no writers means no writes".
@Test func publishNeverEncodesWhenNoWriterIsAttached() async {
    let stream = PreviewStream()
    await stream.publish(stripedBuffer(), mirrored: true)
    await stream.publish(stripedBuffer(), mirrored: false)
    #expect(await stream.framesEncoded == 0)
}

@Test func publishEncodesOnceThereIsAWriterToReceiveIt() async {
    let stream = PreviewStream()
    await stream.attach(FakeWriter())
    await stream.publish(stripedBuffer(), mirrored: true)
    #expect(await stream.framesEncoded == 1)
}
