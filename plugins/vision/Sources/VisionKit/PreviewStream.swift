import CoreVideo
import Foundation
import VCPluginSDK

/// Serves the live camera preview as `multipart/x-mixed-replace`, one JPEG per
/// frame, to every attached HTTP client.
///
/// An actor because writer registration (`attach`) and frame fan-out
/// (`publish`) both have to be free of data races between the camera callback
/// and concurrently-arriving HTTP requests.
///
/// **The preview is encoded only while somebody is attached.** JPEG-encoding
/// every frame for nobody is the second-largest avoidable cost after
/// inference, so `publish` returns before touching `JPEGEncoder` at all when
/// `writers` is empty and no still has been asked for.
public actor PreviewStream {
    /// Matches the `boundary=vcframe` the `Content-Type` header advertises in
    /// `attach`; `multipartChunk` frames every published JPEG with it.
    public static let boundary = "vcframe"

    /// Target preview cadence — deliberately independent of, and slower than,
    /// the inference rates. A human does not need 30 fps to see themselves,
    /// and encoding a JPEG on every raw camera frame costs more than the
    /// preview is worth.
    public static let previewFPS = 10

    private var writers: [UUID: any VCResponseWriter] = [:]
    private var lastPublish: ContinuousClock.Instant?

    /// The most recent JPEG this stream encoded, kept so `/api/state`'s
    /// consumers (and anything else wanting a single frame) can have one
    /// without opening an MJPEG connection. `nil` until the first encode.
    public private(set) var latestJPEG: Data?

    /// Set by `requestStill()`, cleared by the next encode. Lets a caller get
    /// one frame without attaching — and without defeating the idle guard,
    /// which is what keeps encoding off when nobody is watching.
    private var stillWanted = false

    public init() {}

    /// Test-support: the number of currently-attached writers. Production has
    /// no reason to read it, but a test asserting a failing writer was
    /// actually dropped (not merely that its `write` was attempted) needs to
    /// observe the registry shrinking.
    var writerCount: Int { writers.count }

    /// Test-support: how many times `publish` got PAST the idle guard and
    /// attempted an encode. `JPEGEncoder` is a stateless `enum` with no seam
    /// to spy on, so without this counter the guard could be deleted and every
    /// other test here would still pass.
    private(set) var framesEncoded = 0

    /// Sends the multipart response head and registers `writer` to receive
    /// every subsequently published frame, until its `write` throws (the
    /// client disconnected) or the process shuts down.
    ///
    /// If the head write itself fails the writer is never registered: the
    /// caller is already gone and `publish` would just throw on the very next
    /// frame for nothing.
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

    /// Asks for exactly one frame to be encoded and cached in `latestJPEG`,
    /// even with nobody attached. Cleared by the next encode.
    public func requestStill() {
        stillWanted = true
    }

    /// Called once per raw camera frame, before any inference gate — this
    /// stream's own cadence is what keeps it cheap.
    ///
    /// - Parameter mirrored: MUST be the exact value read from
    ///   `connection.isVideoMirrored` for this same frame. See
    ///   `JPEGEncoder.encode` for why this is the one source of truth for both
    ///   flips.
    public func publish(_ buffer: CVPixelBuffer, mirrored: Bool) async {
        guard !writers.isEmpty || stillWanted else { return }

        let now = ContinuousClock.now
        let minInterval = 1.0 / TimeInterval(Self.previewFPS)
        if !stillWanted, let last = lastPublish, visionSeconds(now - last) < minInterval { return }
        lastPublish = now
        stillWanted = false

        framesEncoded += 1
        guard let jpeg = JPEGEncoder.encode(buffer, quality: 0.6, mirrored: mirrored) else { return }
        latestJPEG = jpeg
        guard !writers.isEmpty else { return }

        let chunk = Self.multipartChunk(jpeg, boundary: Self.boundary)
        for (id, writer) in writers {
            do {
                try await writer.write(chunk)
            } catch {
                // The client disconnected (or some other write failure). Drop
                // it without disturbing anyone else attached.
                writers.removeValue(forKey: id)
            }
        }
    }

    /// Drops every attached writer. Called on shutdown so nothing is left
    /// holding a half-written multipart response.
    public func detachAll() {
        writers.removeAll()
    }

    /// Pure framing, `static` so it is testable without a live stream: one
    /// multipart part carrying `jpeg` as `image/jpeg`, per RFC 2046 §5.1.1 (a
    /// leading `--boundary` line, part headers, a blank line, the body, then a
    /// trailing CRLF before the next part's boundary).
    public static func multipartChunk(_ jpeg: Data, boundary: String) -> Data {
        var head = "--\(boundary)\r\n"
        head += "Content-Type: image/jpeg\r\n"
        head += "Content-Length: \(jpeg.count)\r\n\r\n"
        var data = Data(head.utf8)
        data.append(jpeg)
        data.append(Data("\r\n".utf8))
        return data
    }
}
