import CoreVideo
import Foundation
import VCPluginSDK

/// Serves the live camera preview as `multipart/x-mixed-replace`, one JPEG
/// per frame, to every attached HTTP client. Task 15 registers the
/// `/preview.mjpeg` route and wires the raw-frame source into `publish`;
/// this type is the whole streaming/encoding mechanism, independently of
/// that wiring.
///
/// An actor because writer registration (`attach`) and frame fan-out
/// (`publish`) both need to be free of data races across `DetectionEngine`'s
/// camera-callback path and whatever concurrently-arriving HTTP requests
/// attach new clients.
public actor PreviewStream {
    /// Matches the `boundary=vcframe` the `Content-Type` header advertises
    /// in `attach`; `multipartChunk` frames every published JPEG with it.
    public static let boundary = "vcframe"

    /// Target preview cadence — deliberately independent of, and slower
    /// than, `DetectionEngine`'s 15fps Vision analysis throttle. The
    /// preview does not need Vision's frame rate to look smooth to a human,
    /// and encoding a JPEG on every raw camera frame would cost more than
    /// the preview is worth.
    private static let minInterval: TimeInterval = 1.0 / 10.0

    private var writers: [UUID: any VCResponseWriter] = [:]
    private var lastPublish: ContinuousClock.Instant?

    public init() {}

    /// Test-support entry point: the number of currently-attached writers.
    /// Production code has no reason to read this — `publish`'s idle guard
    /// below is the only consumer that matters — but a test asserting a
    /// failing writer was actually dropped (not merely that its `write`
    /// was attempted) needs some way to observe the registry shrinking.
    var writerCount: Int { writers.count }

    /// Test-support entry point: how many times `publish` has gotten PAST
    /// the idle guard below and attempted an encode. Exists because "no
    /// writers attached means `JPEGEncoder` is never touched" is otherwise
    /// unobservable from outside this actor — `JPEGEncoder` is a stateless
    /// `enum`, not something a test can inject a spy into — so without
    /// this counter that guard could be deleted and every other test in
    /// this file would still pass.
    private(set) var framesEncoded = 0

    /// Sends the multipart response head and registers `writer` to receive
    /// every subsequently published frame, until its `write` throws (the
    /// client disconnected — see `publish`) or the process shuts down.
    /// If the head write itself fails, the writer is never registered: the
    /// caller is already gone and `publish` would just throw on the very
    /// next frame for nothing.
    public func attach(_ writer: any VCResponseWriter) async {
        do {
            try await writer.writeHead(status: 200, headers: [
                "Content-Type": "multipart/x-mixed-replace; boundary=\(Self.boundary)",
                "Cache-Control": "no-store",
            ])
        } catch {
            return
        }
        writers[UUID()] = writer
    }

    /// Called once per raw camera frame (independent of, and typically more
    /// often than, `DetectionEngine`'s Vision-analysis throttle — the
    /// preview-rate throttle above is what keeps this cheap).
    ///
    /// Idles for free when nobody is attached: returns before touching
    /// `JPEGEncoder` at all, so encoding JPEGs into a void never happens.
    ///
    /// - Parameter mirrored: MUST be the exact `LandmarkFrame.mirrored`
    ///   value produced for this same frame — see `JPEGEncoder.encode`'s
    ///   doc comment for why this is the one and only source of truth for
    ///   both flips.
    public func publish(_ buffer: CVPixelBuffer, mirrored: Bool) async {
        guard !writers.isEmpty else { return }

        let now = ContinuousClock.now
        if let last = lastPublish, Self.seconds(now - last) < Self.minInterval { return }
        lastPublish = now

        framesEncoded += 1
        guard let jpeg = JPEGEncoder.encode(buffer, quality: 0.6, mirrored: mirrored) else { return }
        let chunk = Self.multipartChunk(jpeg, boundary: Self.boundary)

        for (id, writer) in writers {
            do {
                try await writer.write(chunk)
            } catch {
                // The client disconnected (or some other write failure).
                // Drop it without disturbing anyone else attached.
                writers.removeValue(forKey: id)
            }
        }
    }

    /// Pure framing, `static` so it is testable without a live stream: one
    /// multipart part carrying `jpeg` as `image/jpeg`, per RFC 2046 §5.1.1
    /// (a leading `--boundary` line, part headers, a blank line, the body,
    /// then a trailing CRLF before the next part's boundary).
    public static func multipartChunk(_ jpeg: Data, boundary: String) -> Data {
        var head = "--\(boundary)\r\n"
        head += "Content-Type: image/jpeg\r\n"
        head += "Content-Length: \(jpeg.count)\r\n\r\n"
        var data = Data(head.utf8)
        data.append(jpeg)
        data.append(Data("\r\n".utf8))
        return data
    }

    /// `static` (not actor-isolated) and pure, matching `DetectionEngine`'s
    /// identical helper for the same reason: a `Duration`'s components need
    /// converting to a plain `TimeInterval` for the throttle comparison
    /// above.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
