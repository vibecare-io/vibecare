import SwiftUI

struct VibeCheckScreen: View {
    @StateObject private var viewModel = VibeCheckViewModel()

    var body: some View {
        ZStack {
            if viewModel.permissionDenied {
                permissionView
            } else {
                CameraPreview(previewLayer: viewModel.camera.previewLayer)
                    .ignoresSafeArea()
                DetectionOverlay(frame: viewModel.latestFrame)
                    .ignoresSafeArea()
            }
        }
        .navigationTitle("VibeCheck")
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.system(size: 40))
            Text("Camera access is off").font(.title3).bold()
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
