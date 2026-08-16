import Foundation
import VCPluginSDK
import VisionKit

/// Holds the `VCHost` the provider publishes through, once one exists.
///
/// The whole reason this type exists is the startup ORDER. Routes must be
/// registered before `VCHost.connect()`, the routes need the provider, and the
/// provider needs a publisher — so the provider is necessarily built before
/// there is any host to publish through. The alternatives are worse: making
/// `VisionProvider.publisher` mutable would put a `var` on the frame path's hot
/// side, and connecting first would serve 502s for as long as it took to
/// register the routes.
///
/// Before `attach`, `publish` throws. That is correct and not a gap: the
/// provider counts a failed publish and moves on, and nothing can have been
/// produced yet anyway — capture starts only from a plan, and a plan needs a
/// demand event that can only arrive over the connection this is waiting for.
final class VisionDeferredPublisher: VisionPublisher, @unchecked Sendable {
    /// `@unchecked` under the usual argument: the one piece of mutable state
    /// is written once and read from the publish pump, both under this lock.
    /// The `await` on the RPC happens outside it — holding a lock across a
    /// suspension is how an actor-reentrant publish path deadlocks.
    private let lock = NSLock()
    private var host: VCHost?

    func attach(_ host: VCHost) {
        lock.withLock { self.host = host }
    }

    func publish(topic: String, payload: Data) async throws {
        guard let host = lock.withLock({ self.host }) else {
            throw VisionPublisherError.notConnected
        }
        // `VCHost.publish` puts the SDK's 5 s deadline on the call. Neither
        // `Publish` nor `Alert` carries one by default, and a provider
        // publishing at frame rate against a wedged core would otherwise pile
        // up tasks until the process died.
        try await host.publish(topic: topic, payload: payload)
    }
}

enum VisionPublisherError: Error {
    case notConnected
}

/// The synchronous view of health that `VCHost.setHealth` requires.
///
/// `setHealth`'s closure cannot `await`, and every fact worth reporting lives
/// behind an actor. So a slow loop refreshes this and the probe reads it — a
/// probe must never be able to stall behind a frame, and core polls on its own
/// timer regardless of what this process is doing.
///
/// The one condition worth reporting is the one a user can act on: something
/// asked for the camera and the camera cannot be had. A vision that nobody has
/// asked anything of is perfectly healthy with the LED off, and saying
/// otherwise would train people to ignore the field.
final class VisionHealthCache: @unchecked Sendable {
    private let lock = NSLock()
    private var status = "ok"
    private var detail = ""

    func current() -> (status: String, detail: String) {
        lock.withLock { (status, detail) }
    }

    func update(from snapshot: VisionSnapshot) {
        // Only topics that cost a model can want the camera; `signals` is pure
        // math and runs off whatever the others produced.
        let wantsCamera = snapshot.topics.contains { $0.running && $0.model != nil }
        let (status, detail): (String, String) = {
            guard wantsCamera, !snapshot.capturing else { return ("ok", "") }
            switch snapshot.permission {
            case .denied:
                return ("degraded", "camera access denied — grant it in System Settings › Privacy & Security › Camera")
            case .noDevice:
                return ("degraded", "no camera device is attached")
            case .unknown, .granted:
                // Asked for, permitted (or not yet asked), and still not open:
                // the provider is between its retry backoff and its next
                // attempt. Transient by construction, so not worth a degraded
                // reading that would clear itself a second later.
                return ("ok", "")
            }
        }()
        // Core force-clears `detail` on any transition to up, so a detail
        // carried alongside "ok" only misleads whoever reads this plugin's
        // /health directly. Written as a pair so the two can never drift.
        lock.withLock {
            self.status = status
            self.detail = detail
        }
    }
}
