import Foundation
import Testing
@testable import BlinkJumpKit

// These tests hand-assemble protobuf bytes rather than going through the
// generated `VCTSignals`/`VCTRequest`. That is the point: encoding the message
// with the same generated code that decodes it would pass just as happily if
// the field numbers were wrong on both sides. Bytes pin the contract to
// `proto/topics/v1/vision.proto` itself.

private func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}

private func fixed32(_ value: Float) -> [UInt8] {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
}

/// `vibecare.topics.v1.Signals`: header = 1 (message), ear_l = 2, ear_r = 3
/// (both `optional float`, so wire type 5, and OMITTED when nil).
private func signalsPayload(earL: Float?, earR: Float?, seq: UInt64? = nil) -> Data {
    var bytes: [UInt8] = []
    if let seq {
        let header: [UInt8] = [0x10] + varint(seq)     // Header.seq = 2, varint
        bytes += [0x0A] + varint(UInt64(header.count)) + header
    }
    if let earL { bytes += [0x15] + fixed32(earL) }    // (2 << 3) | 5
    if let earR { bytes += [0x1D] + fixed32(earR) }    // (3 << 3) | 5
    return Data(bytes)
}

@Test func anOmittedEarDecodesAsAbsentAndAZeroEarDecodesAsZero() {
    // The single easiest thing to get wrong in this whole plugin. `GetEarL()`
    // in Go and `signals.earL` in Swift both answer 0 for these two payloads;
    // only presence tells them apart, and one of them means "no measurement"
    // while the other means "measured, and the eye is shut".
    let omitted = VisionSignalSample.decode(signalsPayload(earL: nil, earR: nil))
    #expect(omitted?.earL == nil)
    #expect(omitted?.earR == nil)

    let explicitZero = VisionSignalSample.decode(signalsPayload(earL: 0, earR: 0))
    #expect(explicitZero?.earL == 0.0)
    #expect(explicitZero?.earR == 0.0)
}

@Test func anEmptyPayloadIsAValidMessageMeaningNothingMeasured() {
    // "No message" and "an empty message" are different statements and a
    // consumer must treat them differently: this one is a real frame in which
    // nothing was detected, so it decodes rather than failing.
    let sample = VisionSignalSample.decode(Data())
    #expect(sample != nil)
    #expect(sample?.earL == nil)
    #expect(sample?.seq == 0)
}

@Test func earsAndSequenceDecodeFromTheWire() {
    let sample = VisionSignalSample.decode(signalsPayload(earL: 0.32, earR: 0.29, seq: 4242))
    #expect(sample?.seq == 4242)
    #expect(abs((sample?.earL ?? 0) - 0.32) < 1e-6)
    #expect(abs((sample?.earR ?? 0) - 0.29) < 1e-6)
}

@Test func aPayloadThatIsNotSignalsDecodesToNil() {
    // A length-delimited field claiming five bytes that are not there.
    #expect(VisionSignalSample.decode(Data([0x0A, 0x05])) == nil)
}

@Test func requestEncodesTheFieldNumbersTheProviderReads() {
    // vibecare.topics.v1.Request: requester = 1, topics = 2 (repeated string),
    // fps = 3, ttl_s = 4.
    let intent = VisionRequestIntent(
        requester: "blink-jump",
        topics: [VisionTopic.signals],
        fps: 30,
        ttlSeconds: 30
    )
    var expected: [UInt8] = []
    expected += [0x0A, 0x0A] + Array("blink-jump".utf8)
    expected += [0x12, 0x11] + Array("vision.signals.v1".utf8)
    expected += [0x18, 30]
    expected += [0x20, 30]

    #expect(Array(intent.encoded()) == expected)
}

@Test func aRetractionPutsAnEmptyTopicListOnTheWire() {
    // `topics: []` is a meaningful value, not a missing one: latest-wins per
    // requester, so this is what releases the camera. A repeated field with no
    // elements encodes as no bytes at all — which is exactly right, and is the
    // reason `requester` has to be present for the provider to know WHOSE
    // request just became empty.
    let retraction = VisionRequestIntent(requester: "blink-jump", topics: [], fps: 30, ttlSeconds: 30)
    var expected: [UInt8] = []
    expected += [0x0A, 0x0A] + Array("blink-jump".utf8)
    expected += [0x18, 30]
    expected += [0x20, 30]

    #expect(Array(retraction.encoded()) == expected)
}

@Test func demandDecodesTheKernelsJSONBody() {
    // `_core.demand.v1`'s body is core's wire contract, not ours.
    let payload = Data(#"{"topic":"vision.request.v1","subscribers":1}"#.utf8)
    #expect(VCDemandReading.decode(payload) == VCDemandReading(topic: "vision.request.v1", subscribers: 1))
    #expect(VCDemandReading.decode(Data("not json".utf8)) == nil)
}
