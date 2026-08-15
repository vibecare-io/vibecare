import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Encodes a raw camera frame as a JPEG for `/preview.mjpeg` (Task 15 wires
/// the route; this type is the whole encoding step, independently testable
/// with a synthetic `CVPixelBuffer` — no camera required).
public enum JPEGEncoder {
    /// One `CIContext` for the process's entire lifetime. Constructing a
    /// fresh one per frame stands up a new Metal/GPU pipeline every call —
    /// expensive enough to dominate the frame budget on its own.
    private static let context = CIContext()

    /// - Parameters:
    ///   - mirrored: whether the SOURCE connection already mirrored x. This
    ///     MUST be the exact `LandmarkFrame.mirrored` value produced for
    ///     this same camera frame (see that property's doc comment in
    ///     Geometry.swift) — the single source of truth both the landmark
    ///     flip (`ViewerSpace.point`/`.rect`) and this image flip derive
    ///     from. Never re-derive this from `AVCaptureDevice.position` or
    ///     read `connection.isVideoMirrored` a second time here: doing so
    ///     risks the two surfaces disagreeing about which side is which,
    ///     which is exactly the wrong-side-overlay bug this parameter
    ///     exists to prevent (see `JPEGEncoderTests.imageFlipAgreesWith...`).
    ///   - quality: JPEG lossy-compression quality, 0...1.
    /// - Returns: JPEG-encoded bytes, or `nil` if Core Image could not
    ///   produce a representation (e.g. a malformed buffer).
    public static func encode(_ buffer: CVPixelBuffer, quality: Double, mirrored: Bool) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        // `mirrored == false` means the raw frame is NOT already mirrored,
        // so — same condition as `ViewerSpace.point`/`.rect`'s `mirrored ?
        // p.x : 1 - p.x` — this flips it into viewer space. `.upMirrored`
        // is a horizontal (left-right) flip; horizontal flips are their
        // own inverse, so the EXIF-orientation "which way is this stored"
        // framing `oriented(_:)` normally implies doesn't change which
        // transform actually gets applied here.
        if !mirrored {
            image = image.oriented(.upMirrored)
        }
        let qualityOption = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [qualityOption: quality]
        return context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options)
    }
}
