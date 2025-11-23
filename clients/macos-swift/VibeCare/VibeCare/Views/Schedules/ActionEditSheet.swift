import SwiftUI

struct ActionEditSheet: View {
    let profileId: String
    let schedule: Schedule
    let initialActionCard: ScheduleActionCard
    let isCreating: Bool
    let onSave: (ScheduleActionCard) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var actionService = ActionService()
    @State private var viewModel: NotificationActionViewModel
    @State private var actionType: ActionType
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        profileId: String,
        schedule: Schedule,
        actionCard: ScheduleActionCard,
        isCreating: Bool,
        onSave: @escaping (ScheduleActionCard) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profileId = profileId
        self.schedule = schedule
        self.initialActionCard = actionCard
        self.isCreating = isCreating
        self.onSave = onSave
        self.onCancel = onCancel

        // Initialize state properties
        self._actionType = State(initialValue: actionCard.type)
        self._viewModel = State(initialValue: NotificationActionViewModel(
            preferences: actionCard.notificationPreferences,
            parameters: actionCard.parameters
        ))
    }

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

                        Picker("Action Type", selection: $actionType) {
                            ForEach(ActionType.allCases, id: \.self) { type in
                                Label(type.displayName, systemImage: type.iconName)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: actionType) { _, newType in
                            // Reset ViewModel when type changes
                            viewModel = NotificationActionViewModel(
                                preferences: .default,
                                parameters: [:]
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                // Action configuration card
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if actionType == .notification {
                            NotificationActionParametersView(viewModel: viewModel)
                        } else {
                            ActionParametersView(
                                type: actionType,
                                parameters: $viewModel.parameters
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
        // Special handling for notification type - check preferences instead of parameters
        if actionType == .notification {
            // For notifications, title and body are optional (can use defaults)
            // So notification actions are always valid
            return true
        }

        // For other action types, validate required parameters
        let requiredParams = actionType.requiredParameters.filter { $0.required }
        return requiredParams.allSatisfy { param in
            if let value = viewModel.parameters[param.name] {
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    private func saveAction() async {
        isSaving = true
        errorMessage = nil

        do {
            // Serialize ViewModel preferences to parameters
            viewModel.serializeToParameters()

            // Create updated action card from ViewModel state
            var updatedCard = initialActionCard
            updatedCard.type = actionType
            updatedCard.parameters = viewModel.parameters
            updatedCard.notificationPreferences = viewModel.preferences

            // Convert to Action for API call
            var action = updatedCard.toAction(
                profileId: profileId,
                scheduleName: schedule.name,
                scheduleNotes: schedule.notes
            )
            action.enabled = true

            if isCreating {
                // Create the action
                let createdAction = try await actionService.createAction(action)

                // Associate the action with the schedule
                let scheduleService = ScheduleService()

                // Get current action count to determine proper ordering
                let existingActionIds = try await scheduleService.getScheduleActions(scheduleId: schedule.id)
                let actionOrder = existingActionIds.count

                // Add action to schedule via join table
                try await scheduleService.addActionToSchedule(
                    scheduleId: schedule.id,
                    actionId: createdAction.id,
                    order: actionOrder
                )
            } else {
                _ = try await actionService.updateAction(action)
            }

            await MainActor.run {
                onSave(updatedCard)
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
        actionCard: ScheduleActionCard(type: .notification),
        isCreating: true,
        onSave: { _ in },
        onCancel: {}
    )
}
