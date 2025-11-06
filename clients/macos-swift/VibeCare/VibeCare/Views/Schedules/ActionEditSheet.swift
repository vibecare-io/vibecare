import SwiftUI

struct ActionEditSheet: View {
    let profileId: String
    let schedule: Schedule
    @Binding var actionCard: ScheduleActionCard
    let isCreating: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionService = ActionService()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(isCreating ? "Add Action" : "Edit Action")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Configure action for '\(schedule.name)'")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                Divider()

                // Action type picker (only for new actions)
                if isCreating {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Action Type")
                            .font(.headline)

                        Picker("Action Type", selection: Binding(
                            get: { actionCard.type },
                            set: { newType in
                                // Reset card when type changes
                                actionCard = ScheduleActionCard(type: newType)
                            }
                        )) {
                            ForEach(ActionType.allCases, id: \.self) { type in
                                Label(type.displayName, systemImage: type.iconName)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal)
                }

                // Action configuration card
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if actionCard.type == .notification {
                            NotificationActionParametersView(
                                preferences: Binding(
                                    get: { actionCard.notificationPreferences ?? .default },
                                    set: { actionCard.notificationPreferences = $0 }
                                ),
                                parameters: $actionCard.parameters
                            )
                        } else {
                            ActionParametersView(
                                type: actionCard.type,
                                parameters: $actionCard.parameters
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                // Error message
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Add" : "Save") {
                        Task {
                            await saveAction()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !isValid)
                }
            }
        }
        .frame(width: 600, height: 700)
    }

    private var isValid: Bool {
        // Basic validation - ensure required parameters are filled
        let requiredParams = actionCard.type.requiredParameters
        return requiredParams.allSatisfy { param in
            if let value = actionCard.parameters[param.name] {
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    private func saveAction() async {
        isSaving = true
        errorMessage = nil

        do {
            var action = actionCard.toAction(
                profileId: profileId,
                scheduleName: schedule.name,
                scheduleNotes: schedule.notes
            )
            action.enabled = true

            if isCreating {
                _ = try await actionService.createAction(action)
            } else {
                _ = try await actionService.updateAction(action)
            }

            await MainActor.run {
                onSave()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save action: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }
}

#Preview {
    ActionEditSheet(
        profileId: "test",
        schedule: Schedule(
            profileId: "test",
            routineId: "routine1",
            name: "Test Schedule",
            rrule: "FREQ=DAILY"
        ),
        actionCard: .constant(ScheduleActionCard(type: .notification)),
        isCreating: true,
        onSave: {},
        onCancel: {}
    )
}
