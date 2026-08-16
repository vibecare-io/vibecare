import Foundation
import VCPluginSDK

/// Adapts the live `VCHost` to `BusPublisher`.
///
/// The indirection exists so `VisionRequester` — which holds the whole camera
/// demand story — can be driven by a test with no unix socket, no kernel and
/// no gRPC. `VCHost` itself can only be built by `connect()`, which dials one.
public struct HostPublisher: BusPublisher {
    private let host: VCHost

    public init(host: VCHost) {
        self.host = host
    }

    /// `VCHost.publish` already carries the 5 s deadline every unary call
    /// needs — neither `Publish` nor `Alert` has one by default, and both can
    /// block indefinitely against a wedged core.
    public func publish(topic: String, payload: Data) async throws {
        try await host.publish(topic: topic, payload: payload)
    }
}
