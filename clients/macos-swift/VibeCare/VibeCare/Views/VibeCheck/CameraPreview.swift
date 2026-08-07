import SwiftUI
import AVFoundation

struct CameraPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        previewLayer.frame = view.bounds
        view.layer = previewLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Only manage the layer frame. Mirroring is left to the system's
        // automaticallyAdjustsVideoMirroring default (see CameraSession):
        // manually forcing isVideoMirrored here only stuck when the layer's
        // connection was ready, which flipped the overlay on first-open vs
        // re-open depending on timing.
        previewLayer.frame = nsView.bounds
    }
}
