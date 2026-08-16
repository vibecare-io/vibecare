import CoreVideo
import Foundation
import VCKStubs
@testable import VisionKit

/// A `VisionAnalyzing` that records instead of inferring.
///
/// The whole reason `VisionAnalyzing` exists: which models are constructed,
/// which are released, and which run on a given frame are decisions about sets
/// and rates. They must be assertable on a machine with no camera and without
/// waiting on the ANE, and none of them need Apple's Vision framework to be
/// involved to be wrong.
///
/// `@unchecked Sendable` for the same reason the real analyzer is: every call
/// arrives on one serial queue. The lock here is belt-and-braces so a test that
/// reads the recordings from the main thread is not itself a race.
final class FakeAnalyzer: VisionAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var activeLocked: Set<VisionTopic> = []
    private var constructedLocked: [Set<VisionTopic>] = []
    private var releasedLocked: [Set<VisionTopic>] = []
    private var runsLocked: [Set<VisionTopic>] = []
    private var headersLocked: [VCTHeader] = []
    private var mirroredLocked: [Bool] = []

    var activeModels: Set<VisionTopic> { lock.withLock { activeLocked } }
    var constructions: [Set<VisionTopic>] { lock.withLock { constructedLocked } }
    var releases: [Set<VisionTopic>] { lock.withLock { releasedLocked } }
    /// One entry per `analyze` call: the topics it was asked to run.
    var runs: [Set<VisionTopic>] { lock.withLock { runsLocked } }
    var headers: [VCTHeader] { lock.withLock { headersLocked } }
    var mirroredSeen: [Bool] { lock.withLock { mirroredLocked } }

    @discardableResult
    func setActiveModels(_ topics: Set<VisionTopic>) -> VisionModelChange {
        lock.withLock {
            let wanted = topics.intersection(VisionModelTopics)
            let change = VisionModelChange(constructed: wanted.subtracting(activeLocked),
                                           released: activeLocked.subtracting(wanted))
            activeLocked = wanted
            if !change.constructed.isEmpty { constructedLocked.append(change.constructed) }
            if !change.released.isEmpty { releasedLocked.append(change.released) }
            return change
        }
    }

    func analyze(_ buffer: CVPixelBuffer,
                 run: Set<VisionTopic>,
                 header: VCTHeader,
                 mirrored: Bool) -> VisionFrameBundle {
        let due = lock.withLock { () -> Set<VisionTopic> in
            let due = run.intersection(activeLocked)
            runsLocked.append(due)
            headersLocked.append(header)
            mirroredLocked.append(mirrored)
            return due
        }
        var bundle = VisionFrameBundle(header: header)
        // Every model that ran emits a payload, even an empty one: "the model
        // ran and saw nothing" is a message consumers must receive, and it is
        // a different statement from no message at all.
        if due.contains(.face) {
            var frame = VCTFaceFrame()
            frame.header = header
            frame.confidence = 0.9
            bundle.face = frame
        }
        if due.contains(.hands) {
            var frame = VCTHandsFrame()
            frame.header = header
            bundle.hands = frame
        }
        if due.contains(.bodyPose) {
            var frame = VCTBodyPoseFrame()
            frame.header = header
            bundle.body = frame
        }
        if due.contains(.segmentation) {
            var frame = VCTSegmentationFrame()
            frame.header = header
            frame.w = 64
            frame.h = 48
            bundle.segmentation = frame
        }
        return bundle
    }
}

/// Records everything the frame path handed to the publish queue.
final class PublishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messagesLocked: [(topic: VisionTopic, payload: Data)] = []

    var messages: [(topic: VisionTopic, payload: Data)] { lock.withLock { messagesLocked } }
    var topics: [VisionTopic] { messages.map(\.topic) }

    func record(_ topic: VisionTopic, _ payload: Data) {
        lock.withLock { messagesLocked.append((topic, payload)) }
    }

    func reset() { lock.withLock { messagesLocked.removeAll() } }

    func payloads(_ topic: VisionTopic) -> [Data] {
        messages.filter { $0.topic == topic }.map(\.payload)
    }
}

/// A `VisionPublisher` that records, and can be told to fail.
actor SpyPublisher: VisionPublisher {
    private(set) var published: [(topic: String, payload: Data)] = []
    var shouldThrow = false

    struct Failure: Error {}

    func publish(topic: String, payload: Data) async throws {
        if shouldThrow { throw Failure() }
        published.append((topic, payload))
    }

    func setShouldThrow(_ value: Bool) { shouldThrow = value }
}

/// A synthetic BGRA buffer — enough for the frame path, which only reads its
/// dimensions, and enough for `JPEGEncoder`, which encodes whatever is in it.
func makeTestPixelBuffer(width: Int = 64, height: Int = 48, fill: UInt8 = 0x40) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                     &buffer)
    guard status == kCVReturnSuccess, let buffer else {
        fatalError("could not create a test pixel buffer (status \(status))")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * height)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// Builds a `VisionPlan` directly, so a test about the frame path does not
/// have to restate the whole control plane to get one.
func testPlan(_ entries: [VisionTopic: Int], warnings: [VisionWarning] = []) -> VisionPlan {
    VisionPlan(
        topics: entries.reduce(into: [:]) { out, entry in
            out[entry.key] = VisionTopicPlan(fps: entry.value, subscribers: 1, requesters: ["test"])
        },
        warnings: warnings
    )
}

/// A `vision.request.v1` message.
func testRequest(_ requester: String,
                 _ topics: [VisionTopic],
                 fps: UInt32 = 0,
                 ttl: UInt32 = 0) -> VCTRequest {
    var request = VCTRequest()
    request.requester = requester
    request.topics = topics.map(\.name)
    request.fps = fps
    request.ttlS = ttl
    return request
}
