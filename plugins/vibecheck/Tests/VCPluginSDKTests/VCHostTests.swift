import Testing
import Foundation
@testable import VCPluginSDK

@Test func cleanStreamEndIsTreatedAsAReconnect() {
    // rpc.go:146-149 returns nil when a non-superseded cancel closes the
    // subscriber channel. In grpc-swift that surfaces as an AsyncSequence
    // that simply finishes — nothing thrown. A do/catch-driven loop would
    // fall out and never reconnect again.
    #expect(VCSessionOutcome.classify(error: nil) == .reconnect)
    #expect(VCSessionOutcome.classify(error: VCHostError.streamEnded) == .reconnect)
}

@Test func shutdownRequestIsTheOnlyNonReconnectOutcome() {
    #expect(VCSessionOutcome.classify(error: VCHostError.shutdownRequested) == .stop)
    // A registration core will never accept still reconnects: a core restart
    // with a corrected manifest must recover without a plugin restart.
    #expect(VCSessionOutcome.classify(error: VCHostError.registrationRejected("no such plugin")) == .reconnect)
    #expect(VCSessionOutcome.classify(error: VCHostError.readyTimeout) == .reconnect)
}

@Test func healthBodyOmitsDetailWhenOk() throws {
    // health.go:179-181 force-clears detail on any transition to up, so a
    // detail string alongside "ok" is silently discarded. Do not emit one.
    let ok = VCHealthBody(status: "ok", detail: "camera warming")
    let encoded = String(decoding: try JSONEncoder().encode(ok.normalized()), as: UTF8.self)
    #expect(encoded.contains("\"status\":\"ok\""))
    #expect(!encoded.contains("camera warming"))

    let degraded = VCHealthBody(status: "degraded", detail: "camera unavailable")
    let d = String(decoding: try JSONEncoder().encode(degraded.normalized()), as: UTF8.self)
    #expect(d.contains("camera unavailable"))
}

@Test func demandPayloadDecodes() throws {
    let json = Data(#"{"topic":"sensor.landmarks.v1","subscribers":2}"#.utf8)
    let d = try JSONDecoder().decode(VCDemand.self, from: json)
    #expect(d.topic == "sensor.landmarks.v1")
    #expect(d.subscribers == 2)
    #expect(VCTopicDemand == "_core.demand.v1")
}
