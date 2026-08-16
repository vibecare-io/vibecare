import CoreVideo
import Foundation
import VCKStubs

/// Which models were constructed and which were released by one
/// `setActiveModels` call.
public struct VisionModelChange: Sendable, Equatable {
    public var constructed: Set<VisionTopic>
    public var released: Set<VisionTopic>

    public init(constructed: Set<VisionTopic> = [], released: Set<VisionTopic> = []) {
        self.constructed = constructed
        self.released = released
    }

    public var isEmpty: Bool { constructed.isEmpty && released.isEmpty }
}

/// The inference seam.
///
/// Everything that touches the Vision framework sits behind this, for one
/// concrete reason: the decisions worth testing — *which* models exist, when
/// they are released, which ones run on a given frame — are decisions about
/// sets and rates, and they must be assertable on a machine with no camera and
/// without waiting on the ANE. `AppleVisionAnalyzer` is the production
/// conformer; a test double records calls.
///
/// **Confinement contract.** A conformer's `VNRequest`s are reference types
/// whose `.results` are overwritten by each `perform`, so two concurrent
/// `analyze` calls would cross-contaminate. Every method here is called only
/// from `CameraSession.frameQueue`, a single serial queue, which is what makes
/// the `Sendable` conformance honest without any locking inside the analyzer.
/// `FrameProcessor` is the only caller and it upholds this.
public protocol VisionAnalyzing: AnyObject, Sendable {
    /// The topics whose models currently exist.
    var activeModels: Set<VisionTopic> { get }

    /// Makes exactly `topics` live: constructs anything newly needed, and
    /// **releases anything no longer needed**. An idle `VNRequest` still holds
    /// resources, so a topic that lost its demand or its last requester must
    /// not leave one parked.
    ///
    /// Only topics with a `model` are meaningful here; a conformer ignores the
    /// rest.
    @discardableResult
    func setActiveModels(_ topics: Set<VisionTopic>) -> VisionModelChange

    /// Runs exactly the models named by `run` (intersected with
    /// `activeModels`) against one pixel buffer.
    ///
    /// - Parameters:
    ///   - run: the topics due on this frame, per the independent per-topic
    ///     rate gates.
    ///   - header: built once, before inference, and shared verbatim by every
    ///     topic derived from this frame.
    ///   - mirrored: `connection.isVideoMirrored` for **this** frame. Threaded
    ///     into every coordinate conversion the call performs.
    func analyze(_ buffer: CVPixelBuffer,
                 run: Set<VisionTopic>,
                 header: VCTHeader,
                 mirrored: Bool) -> VisionFrameBundle
}
