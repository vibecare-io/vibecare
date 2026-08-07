import SwiftUI
import AVFoundation

struct CameraPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        previewLayer.frame = view.bounds
        view.layer = previewLayer
        applyMirroring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        previewLayer.frame = nsView.bounds
        // Re-assert mirroring after every (re)attach. On re-navigation the
        // layer's connection can be nil during makeNSView, so setting it only
        // there lets the preview revert to unmirrored — which flips the
        // overlay's alignment (it appears mirrored). updateNSView runs after
        // the layer is attached, when the connection is available.
        applyMirroring()
    }

    /// Pins the preview to a mirrored, selfie-style feed. Deterministic and
    /// idempotent so navigation can't drift it.
    private func applyMirroring() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
