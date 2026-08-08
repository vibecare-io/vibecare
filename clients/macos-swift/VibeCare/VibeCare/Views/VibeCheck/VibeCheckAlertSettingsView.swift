import SwiftUI

/// Advanced, per-behavior customization for the VibeCheck detection alert.
/// Reuses `NotificationCustomizationView`; edits persist via the shared store.
struct VibeCheckAlertSettingsView: View {
    @StateObject private var store = DetectionAlertPreferencesStore.shared
    @State private var selected: BFRBBehavior = .nailBiting

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Behavior", selection: $selected) {
                ForEach(BFRBBehavior.allCases) { b in Text(b.label).tag(b) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            NotificationCustomizationView(
                preferences: binding(for: selected),
                scheduleName: selected.label,
                scheduleNotes: selected.nudge,
                variablesHint: "Title & message default to this behavior's label and nudge. \"Nth nudge today\" is appended automatically.",
                onPreview: {
                    VibeNotifyConfig.showBFRBAlert(
                        behavior: selected, count: 1,
                        preferences: store.preferences(for: selected))
                }
            )
        }
        // Reliable auto-save: reading encodedSnapshot tracks every field (Observation),
        // so this fires on any edit to any behavior's prefs.
        .onChange(of: store.encodedSnapshot) { _, _ in store.persist() }
    }

    private func binding(for b: BFRBBehavior) -> Binding<NotificationPreferences> {
        Binding(
            get: { store.preferences(for: b) },
            // Copy on set: preset/reset buttons assign shared static instances
            // (e.g. `NotificationPreferences.presets[name]`, `.default`). Storing
            // the shared instance directly would let multiple behaviors alias the
            // same object; copying here breaks that aliasing. Field-level edits
            // mutate the stored instance in place and never go through this setter.
            set: { store.byBehavior[b.rawValue] = $0.copy() }
        )
    }
}
