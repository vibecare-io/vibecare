import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Encodes a raw camera frame as a JPEG for `/preview.mjpeg`. The whole
/// encoding step, independently testable with a synthetic `CVPixelBuffer` — no
/// camera required.
public enum JPEGEncoder {
    /// One `CIContext` for the process's entire lifetime. Constructing a fresh
    /// one per frame stands up a new Metal/GPU pipeline every call, expensive
    /// enough to dominate the frame budget on its own.
    private static let context = CIContext()

    /// - Parameters:
    ///   - mirrored: whether the SOURCE connection already mirrored x. This
    ///     MUST be the exact value read from `connection.isVideoMirrored` for
    ///     this same frame and threaded through
    ///     `CameraFrameReceiver.didOutput` — the one source of truth both the
    ///     landmark flip (`ViewerSpaceMapping`) and this image flip derive
    ///     from. Never re-derive it from `AVCaptureDevice.position` and never
    ///     read the connection a second time here: the two surfaces
    ///     disagreeing about which side is which is exactly the wrong-side
    ///     overlay this parameter exists to prevent.
    ///   - quality: JPEG lossy-compression quality, 0...1.
    /// - Returns: JPEG bytes, or `nil` if Core Image could not produce a
    ///   representation (a malformed buffer).
    public static func encode(_ buffer: CVPixelBuffer, quality: Double, mirrored: Bool) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        // `mirrored == false` means the raw frame is NOT already mirrored, so
        // — the same condition as `ViewerSpaceMapping.point`'s
        // `mirrored ? p.x : 1 - p.x` — this flips it into viewer space.
        // `.upMirrored` is a horizontal flip; horizontal flips are their own
        // inverse, so the EXIF-orientation "which way is this stored" framing
        // that `oriented(_:)` normally implies does not change which transform
        // actually gets applied.
        if !mirrored {
            image = image.oriented(.upMirrored)
        }
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        return context.jpegRepresentation(of: image,
                                          colorSpace: CGColorSpaceCreateDeviceRGB(),
                                          options: [qualityKey: quality])
    }
}
