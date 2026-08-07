import SwiftUI

/// The right-hand detail pane for the VibeCheck screen: detection toggles,
/// sensitivity/alert sliders, and live session counts. Shares `viewModel`
/// with `VibeCheckScreen` (owned up in `Dashboard`) so changes here take
/// effect on the live camera feed immediately.
struct VibeCheckControlsPanel: View {
    @ObservedObject var viewModel: VibeCheckViewModel

    var body: some View {
        Form {
            Section("Detection") {
                ForEach(BFRBBehavior.allCases) { behavior in
                    Toggle(behavior.label, isOn: behaviorBinding(behavior))
                }
            }

            Section("Sensitivity") {
                Slider(value: $viewModel.sensitivity, in: 0...1)
            }

            Section("Alerts") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alert interval: \(Int(viewModel.alertInterval))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $viewModel.alertInterval, in: 1...30)
                }
            }

            Section("Session") {
                ForEach(BFRBBehavior.allCases) { behavior in
                    HStack {
                        Text(behavior.label)
                        Spacer()
                        Text("\(viewModel.sessionCounts[behavior, default: 0])")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VibeCheck")
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
}
