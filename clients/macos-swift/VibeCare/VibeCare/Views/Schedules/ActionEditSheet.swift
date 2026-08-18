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
    /// The menu's selection. `ActionType` cannot serve as one — rich and plain
    /// notifications share it — so the picker binds to an `ActionKind.id`.
    @State private var actionKindID: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingPreview = false

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
        // Derived from the card's own parameters, so an action carrying a
        // countdown or a web panel opens on "Send Rich Notification" whether or
        // not it was authored here — see `ActionKind.isRich`.
        self._actionKindID = State(
            initialValue: actionCard.type == .notification
                && ActionKind.isRich(actionCard.parameters)
                ? "notification.rich" : actionCard.type.rawValue)
        self._viewModel = State(initialValue: NotificationActionViewModel(
            preferences: actionCard.notificationPreferences,
            parameters: actionCard.type.seedingDefaults(into: actionCard.parameters),
            overridesAppearance: actionCard.overridesAppearance
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

                        // Selects an `ActionKind`, not an `ActionType`: rich and
                        // plain notifications share a type, so a type picker
                        // shows one entry for two different things and cannot
                        // switch between them.
                        Picker("Action Type", selection: $actionKindID) {
                            ForEach(ActionKind.all) { kind in
                                Label(kind.title, systemImage: kind.icon)
                                    .tag(kind.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: actionKindID) { _, newID in
                            guard let kind = ActionKind.all.first(where: { $0.id == newID })
                            else { return }
                            actionType = kind.type
                            // Reset ViewModel and seed defaults for the new kind.
                            // `seedParameters()` carries the rich marker and the
                            // default activity; `seedingDefaults` fills in the
                            // per-type fields for everything else.
                            viewModel = NotificationActionViewModel(
                                preferences: GlobalNotificationSettings.current.basePreferences(),
                                parameters: kind.type.seedingDefaults(into: kind.seedParameters()),
                                overridesAppearance: false
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
                ToolbarItem(placement: .automatic) {
                    HStack {
                        // Preview button (only for notification actions)
                        if actionType == .notification {
                            Button(action: {
                                showPreviewNotification()
                            }) {
                                Label("Preview", systemImage: "eye")
                            }
                            .disabled(isSaving)

                            if showingPreview {
                                Text("Preview sent!")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .onAppear {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            showingPreview = false
                                        }
                                    }
                            }
                        }

                        Spacer()

                        Button("Cancel") {
                            onCancel()
                            dismiss()
                        }
                        .disabled(isSaving)

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
            // Carried across so `toAction`'s own serialization pass agrees with
            // the one `serializeToParameters()` just made — without this the
            // card would re-add the appearance keys the view model deliberately
            // removed.
            updatedCard.overridesAppearance = viewModel.overridesAppearance

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

    private func showPreviewNotification() {
        _ = VibeNotifyConfig.showScheduleNotification(
            scheduleName: schedule.name,
            routineName: "Preview Action",
            scheduledTime: Date(),
            notes: nil,
            preferences: viewModel.preferences
        )
        showingPreview = true
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
