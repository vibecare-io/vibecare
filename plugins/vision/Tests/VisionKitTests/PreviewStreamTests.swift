import Foundation
import Testing
import VCPluginSDK
@testable import VisionKit

/// A writer that records, and can be told to fail — a disconnected browser.
final class FakeWriter: VCResponseWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var chunksLocked: [Data] = []
    private var headLocked: (status: Int, headers: [String: String])?
    private var failLocked = false

    init(failing: Bool = false) { failLocked = failing }

    struct Broken: Error {}

    var chunks: [Data] { lock.withLock { chunksLocked } }
    var head: (status: Int, headers: [String: String])? { lock.withLock { headLocked } }

    func writeHead(status: Int, headers: [String: String]) async throws {
        if lock.withLock({ failLocked }) { throw Broken() }
        lock.withLock { headLocked = (status, headers) }
    }

    func write(_ chunk: Data) async throws {
        if lock.withLock({ failLocked }) { throw Broken() }
        lock.withLock { chunksLocked.append(chunk) }
    }

    func finish() async throws {}

    func breakIt() { lock.withLock { failLocked = true } }
}

/// The preview is encoded **only while a client is attached**. JPEG-encoding
/// every frame for nobody is the second-largest avoidable cost after
/// inference, and it is invisible from the outside — nothing about a correct
/// MJPEG stream tells you whether the encoder was also running for an empty
/// room. `framesEncoded` is the only observable that can fail.
@Suite struct PreviewStreamTests {
    @Test func nothingIsEncodedWhenNobodyIsAttached() async {
        let stream = PreviewStream()
        // A fresh buffer per call: handing the same one to an actor twice is
        // a sending-risk the compiler rejects, and it is right to.
        for _ in 0..<5 { await stream.publish(makeTestPixelBuffer(), mirrored: true) }

        #expect(await stream.framesEncoded == 0)
        #expect(await stream.latestJPEG == nil)
    }

    @Test func anAttachedClientGetsAMultipartHeadAndFramedJPEGs() async throws {
        let stream = PreviewStream()
        let writer = FakeWriter()
        await stream.attach(writer)

        #expect(writer.head?.status == 200)
        #expect(writer.head?.headers["Content-Type"]
                == "multipart/x-mixed-replace; boundary=\(PreviewStream.boundary)")

        await stream.publish(makeTestPixelBuffer(), mirrored: true)
        #expect(await stream.framesEncoded == 1)
        #expect(writer.chunks.count == 1)

        let chunk = try #require(writer.chunks.first)
        let prefix = String(decoding: chunk.prefix(64), as: UTF8.self)
        #expect(prefix.hasPrefix("--\(PreviewStream.boundary)\r\nContent-Type: image/jpeg\r\n"))
    }

    @Test func aWriterWhoseHeadFailsIsNeverRegistered() async {
        let stream = PreviewStream()
        await stream.attach(FakeWriter(failing: true))
        // The caller is already gone; registering it would just throw on the
        // very next frame for nothing.
        #expect(await stream.writerCount == 0)
        await stream.publish(makeTestPixelBuffer(), mirrored: true)
        #expect(await stream.framesEncoded == 0)
    }

    @Test func aDisconnectedClientIsDroppedWithoutDisturbingTheOthers() async {
        let stream = PreviewStream()
        let good = FakeWriter()
        let doomed = FakeWriter()
        await stream.attach(good)
        await stream.attach(doomed)
        #expect(await stream.writerCount == 2)

        doomed.breakIt()
        await stream.publish(makeTestPixelBuffer(), mirrored: true)

        #expect(await stream.writerCount == 1)
        #expect(good.chunks.count == 1)
    }

    @Test func aStillCanBeTakenWithoutAttachingAndWithoutDefeatingTheIdleGuard() async {
        let stream = PreviewStream()
        await stream.requestStill()
        await stream.publish(makeTestPixelBuffer(), mirrored: true)

        #expect(await stream.framesEncoded == 1)
        #expect(await stream.latestJPEG != nil)

        // One frame, not a subscription: the guard is closed again straight
        // away.
        await stream.publish(makeTestPixelBuffer(), mirrored: true)
        #expect(await stream.framesEncoded == 1)
    }

    @Test func theCadenceThrottleDropsFramesBetweenPreviewIntervals() async {
        let stream = PreviewStream()
        await stream.attach(FakeWriter())

        for _ in 0..<5 { await stream.publish(makeTestPixelBuffer(), mirrored: true) }

        // 10 fps: five back-to-back frames are one encode, not five. A human
        // does not need 30 fps to see themselves.
        #expect(await stream.framesEncoded == 1)
    }

    @Test func multipartFramingMatchesRFC2046() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let chunk = PreviewStream.multipartChunk(jpeg, boundary: "vcframe")
        let text = String(decoding: chunk, as: UTF8.self)
        #expect(text.hasPrefix("--vcframe\r\nContent-Type: image/jpeg\r\nContent-Length: 4\r\n\r\n"))
        #expect(chunk.suffix(2) == Data("\r\n".utf8))
    }
}
