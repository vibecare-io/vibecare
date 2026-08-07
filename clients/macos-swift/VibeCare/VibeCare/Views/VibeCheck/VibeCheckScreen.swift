import SwiftUI

struct VibeCheckScreen: View {
    @ObservedObject var viewModel: VibeCheckViewModel

    var body: some View {
        ZStack {
            if viewModel.permissionDenied {
                permissionView
            } else {
                CameraPreview(previewLayer: viewModel.camera.previewLayer)
                    .ignoresSafeArea()
                if viewModel.showOverlay {
                    DetectionOverlay(frame: viewModel.latestFrame,
                                      enabledBehaviors: viewModel.enabledBehaviors)
                        .ignoresSafeArea()
                }
                flashOverlay
                overlayToggle
            }
        }
        .navigationTitle("VibeCheck")
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    /// Translucent red flash shown briefly whenever an interrupt fires.
    private var flashOverlay: some View {
        Rectangle()
            .fill(Color.red.opacity(viewModel.flash ? 0.35 : 0))
            .animation(.easeOut(duration: 0.2), value: viewModel.flash)
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    /// Eye toggle at the camera's top-right, shows/hides `DetectionOverlay`.
    private var overlayToggle: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    viewModel.showOverlay.toggle()
                } label: {
                    Image(systemName: viewModel.showOverlay ? "eye" : "eye.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .help(viewModel.showOverlay ? "Hide detection overlay" : "Show detection overlay")
            }
            Spacer()
        }
        .padding()
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
