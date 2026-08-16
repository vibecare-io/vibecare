import CoreVideo
import Foundation
import SwiftProtobuf
import VCGeometry
import VCKStubs

/// Everything one camera frame produced, ready to publish.
///
/// **Absent is not empty.** A `nil` field means the model did not run on this
/// frame — nobody asked for that topic, or its rate gate discarded this frame.
/// A non-`nil` field with no content (a `FaceFrame` with no points, a
/// `HandsFrame` with no hands) means the model *did* run and detected nothing,
/// which is a valid message consumers must publish and treat differently. The
/// same distinction the wire contract makes, expressed in the type so a
/// publisher cannot collapse it by accident.
public struct VisionFrameBundle: Sendable {
    /// Shared by every topic derived from this frame — that sharing is what
    /// lets a consumer needing face + hands + segmentation from the same
    /// moment join them by `seq`.
    public var header: VCTHeader
    public var face: VCTFaceFrame?
    /// Where each region sits inside `face.points`, **measured** from the
    /// regions the detector actually returned on this frame — never assumed.
    ///
    /// It travels beside the face rather than on the wire because it is not
    /// part of the topic contract: `proto/topics/v1/vision.proto` deliberately
    /// declines to pin the per-region counts, since they are a property of
    /// Apple's constellation and differ between the 65- and 76-point ones.
    /// `VCGeometry` refuses to guess, so without this the signals tier would
    /// have to index a constellation nobody validated — which is how an
    /// eyebrow gets reported as an eye with no assertion firing.
    ///
    /// `nil` when the detector returned a face whose regions do not add up to
    /// its own `allPoints` count. Every face-derived signal is then absent,
    /// which is the contract's honest answer, rather than wrong.
    public var faceLayout: FaceLandmarkLayout?
    public var hands: VCTHandsFrame?
    public var body: VCTBodyPoseFrame?
    public var segmentation: VCTSegmentationFrame?

    public init(header: VCTHeader,
                face: VCTFaceFrame? = nil,
                faceLayout: FaceLandmarkLayout? = nil,
                hands: VCTHandsFrame? = nil,
                body: VCTBodyPoseFrame? = nil,
                segmentation: VCTSegmentationFrame? = nil) {
        self.header = header
        self.face = face
        self.faceLayout = faceLayout
        self.hands = hands
        self.body = body
        self.segmentation = segmentation
    }

    /// Which model topics actually produced a payload on this frame.
    public var produced: Set<VisionTopic> {
        var out: Set<VisionTopic> = []
        if face != nil { out.insert(.face) }
        if hands != nil { out.insert(.hands) }
        if body != nil { out.insert(.bodyPose) }
        if segmentation != nil { out.insert(.segmentation) }
        return out
    }

    /// Serialized payload for a model topic, or `nil` when that topic produced
    /// nothing on this frame.
    public func payload(for topic: VisionTopic) -> Data? {
        do {
            switch topic {
            case .face: return try face?.serializedData()
            case .hands: return try hands?.serializedData()
            case .bodyPose: return try body?.serializedData()
            case .segmentation: return try segmentation?.serializedData()
            case .signals: return nil    // computed separately; see VisionSignalsComputer
            }
        } catch {
            visionLog("could not serialize \(topic.name): \(error)")
            return nil
        }
    }
}

/// Computes `vision.signals.v1` from whatever landmarks this frame produced.
///
/// A seam rather than a direct call, because the math itself lives in the
/// `VCGeometry` target (the vision design §4.2 keeps it deliberately separate
/// and deliberately *not* shipped for consumers to link) and `VisionKit` owns
/// only the capture and control plane. The composition root wires the two
/// together; a `nil` computer means the provider publishes no signals, which
/// it reports honestly in `/api/state` rather than publishing an all-absent
/// message that would look like a working model with nothing to say.
///
/// Implementations must respect the absent-is-not-zero rule: leave `ear_l`
/// unset when `bundle.face` is `nil`, rather than writing `0`, or every
/// consumer reads a permanently closed eye.
public typealias VisionSignalsComputer = @Sendable (VisionFrameBundle) -> VCTSignals?

/// Builds the header every topic from one frame shares.
func visionHeader(seq: UInt64, ts: Date, deviceID: String, width: Int, height: Int) -> VCTHeader {
    var header = VCTHeader()
    // Capture time, sampled before inference ran. Sampling it afterwards would
    // fold inference latency into the timestamp, which a downstream
    // conformance window cannot absorb.
    header.ts = Google_Protobuf_Timestamp(date: ts)
    header.seq = seq
    header.deviceID = deviceID
    var size = VCTSize()
    size.w = UInt32(max(0, width))
    size.h = UInt32(max(0, height))
    header.frame = size
    return header
}
