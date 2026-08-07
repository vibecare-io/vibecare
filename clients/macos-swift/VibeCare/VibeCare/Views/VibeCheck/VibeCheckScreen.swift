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
                flashOverlay
                controlsOverlay
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

    private var controlsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                controlsPanel
                Spacer()
            }
        }
        .padding()
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detection").font(.headline)

            ForEach(BFRBBehavior.allCases) { behavior in
                Toggle(behavior.label, isOn: behaviorBinding(behavior))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitivity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $viewModel.sensitivity, in: 0...1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Alert interval: \(Int(viewModel.alertInterval))s")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $viewModel.alertInterval, in: 1...30)
            }

            Divider()

            sessionCounter
        }
        .padding()
        .frame(width: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var sessionCounter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Session").font(.caption).foregroundStyle(.secondary)
            ForEach(BFRBBehavior.allCases) { behavior in
                HStack {
                    Text(behavior.label)
                    Spacer()
                    Text("\(viewModel.sessionCounts[behavior, default: 0])")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private func behaviorBinding(_ behavior: BFRBBehavior) -> Binding<Bool> {
        Binding(
            get: { viewModel.enabledBehaviors.contains(behavior) },
            set: { isOn in
                if isOn {
                    viewModel.enabledBehaviors.insert(behavior)
                } else {
                    viewModel.enabledBehaviors.remove(behavior)
                }
            }
        )
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
