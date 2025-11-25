import SwiftUI
import Logging

struct ScheduleWizardView: View {
    @ObservedObject var routineViewModel: RoutineViewModel
    @ObservedObject var scheduleViewModel: ScheduleViewModel
    @EnvironmentObject private var appState: AppState

    let onComplete: (String) -> Void // Called with schedule ID when done
    let onCancel: () -> Void

    @State private var currentStep: WizardStep = .selection
    @State private var selectedTemplate: RoutineScheduleTemplate?

    // Customization state
    @State private var routineName: String = ""
    @State private var scheduleName: String = ""
    @State private var scheduleDescription: String = ""
    @State private var routineIcon: String = ""
    @State private var routineColor: String = ""
    @State private var times: [Date] = []
    @State private var actions: [ActionTemplate] = []
    @State private var selectedRoutineId: String? = nil  // Track if user selected existing routine

    @GestureState private var dragOffset: CGFloat = 0
    @State private var contentOffset: CGFloat = 0

    // Template service for loading from backend
    @StateObject private var templateService = ScheduleTemplateService()

    private let logger = Logger(label: "com.vibecare.schedule-wizard")

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressIndicator
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Main content with gesture
            content
                .offset(x: contentOffset + dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .updating($dragOffset) { value, state, _ in
                            // Only allow left swipe (negative values)
                            if value.translation.width < 0 {
                                state = value.translation.width
                            }
                        }
                        .onEnded { value in
                            handleSwipe(translation: value.translation.width)
                        }
                )
        }
        .onChange(of: selectedTemplate) { _, newTemplate in
            initializeCustomizationState(from: newTemplate)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch currentStep {
        case .selection:
            TemplateSelectionView(
                templateService: templateService,
                selectedTemplate: $selectedTemplate,
                onNext: {
                    withAnimation {
                        currentStep = .customization
                    }
                },
                onCancel: onCancel
            )
            .transition(.asymmetric(
                insertion: .move(edge: .leading),
                removal: .move(edge: .leading)
            ))

        case .customization:
            if let template = selectedTemplate {
                TemplateCustomizationView(
                    template: template,
                    routineName: $routineName,
                    scheduleName: $scheduleName,
                    scheduleDescription: $scheduleDescription,
                    routineIcon: $routineIcon,
                    routineColor: $routineColor,
                    times: $times,
                    actions: $actions,
                    selectedRoutineId: $selectedRoutineId,
                    routineViewModel: routineViewModel,
                    onBack: {
                        withAnimation {
                            currentStep = .selection
                        }
                    },
                    onNext: {
                        withAnimation {
                            currentStep = .review
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                ))
            }

        case .review:
            if let template = selectedTemplate {
                TemplateReviewView(
                    template: template,
                    routineName: routineName,
                    scheduleName: scheduleName,
                    scheduleDescription: scheduleDescription,
                    routineIcon: routineIcon,
                    routineColor: routineColor,
                    times: times,
                    actions: actions,
                    onBack: {
                        withAnimation {
                            currentStep = .customization
                        }
                    },
                    onCreate: createRoutineAndSchedule
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
            }
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 16) {
            ForEach(WizardStep.allCases, id: \.self) { step in
                HStack(spacing: 8) {
                    // Step circle
                    ZStack {
                        Circle()
                            .fill(stepColor(step))
                            .frame(width: 28, height: 28)

                        if step.rawValue < currentStep.rawValue {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.caption.bold())
                                .foregroundColor(step == currentStep ? .white : .secondary)
                        }
                    }

                    // Step label
                    Text(step.title)
                        .font(.subheadline)
                        .fontWeight(step == currentStep ? .semibold : .regular)
                        .foregroundColor(step == currentStep ? .primary : .secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(step == currentStep ? Color.accentColor.opacity(0.1) : Color.clear)
                )

                // Connector line
                if step != WizardStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 40, height: 2)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.1), radius: 8, y: 2)
        )
    }

    // MARK: - Gesture Handling

    private func handleSwipe(translation: CGFloat) {
        let swipeThreshold: CGFloat = -100

        // Swipe left to go back
        if translation < swipeThreshold && currentStep != .selection {
            withAnimation(.easeInOut(duration: 0.3)) {
                goToPreviousStep()
            }
        }

        // Reset offset with animation
        withAnimation(.easeOut(duration: 0.2)) {
            contentOffset = 0
        }
    }

    private func goToPreviousStep() {
        switch currentStep {
        case .selection:
            break // Can't go back from first step
        case .customization:
            currentStep = .selection
        case .review:
            currentStep = .customization
        }
    }

    // MARK: - Helpers

    private func stepColor(_ step: WizardStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return .green
        } else if step == currentStep {
            return .accentColor
        } else {
            return Color.secondary.opacity(0.3)
        }
    }

    private func initializeCustomizationState(from template: RoutineScheduleTemplate?) {
        guard let template = template else { return }

        routineName = template.routineName
        scheduleName = template.scheduleName
        scheduleDescription = template.scheduleDescription
        routineIcon = template.notificationIconId ?? ""
        routineColor = template.routineColor
        times = template.defaultTimes.map { $0.toDate() }
        actions = template.suggestedActions
        selectedRoutineId = nil  // Reset when template changes
    }

    // MARK: - Create Routine and Schedule

    private func createRoutineAndSchedule() async -> Bool {
        guard let profile = appState.currentProfile else {
            logger.error("No current profile")
            return false
        }

        do {
            // Step 1: Get or create the routine
            let routineId: String

            if let existingId = selectedRoutineId {
                // User selected an existing routine - reuse it
                logger.info("Using existing routine: \(existingId)")
                routineId = existingId
            } else {
                // Create a new routine
                logger.info("Creating routine: \(routineName)")

                try await routineViewModel.createRoutine(
                    name: routineName,
                    description: scheduleDescription,
                    category: selectedTemplate?.category.rawValue ?? "General",
                    enabled: true
                )

                // Get the created routine to get its ID
                guard let routine = routineViewModel.routines.first(where: { $0.name == routineName }) else {
                    logger.error("Failed to find created routine")
                    return false
                }

                // Update routine metadata (icon and color)
                var updatedRoutine = routine
                updatedRoutine.updateMetadata(
                    category: selectedTemplate?.category.rawValue,
                    color: routineColor,
                    icon: routineIcon,
                    tags: nil
                )
                try await routineViewModel.updateRoutine(updatedRoutine)

                routineId = routine.id
            }

            // Step 2: Create actions
            logger.info("Creating \(actions.count) actions")
            var createdActionIds: [String] = []

            for actionTemplate in actions {
                let action = actionTemplate.toAction(
                    profileId: profile.id,
                    routineName: routineName,
                    scheduleName: scheduleName
                )

                let createdAction = try await ActionService().createAction(action)
                createdActionIds.append(createdAction.id)

                logger.info("Created action: \(createdAction.name)")
            }

            // Step 3: Create schedule with RRule
            logger.info("Creating schedule: \(scheduleName)")

            // Build RRule with times
            let rruleWithTimes = buildRRuleWithTimes(
                baseRRule: selectedTemplate?.rruleString ?? "FREQ=DAILY",
                times: times
            )

            let dtstart = times.first ?? Date()

            let schedule = Schedule(
                profileId: profile.id,
                routineId: routineId,
                name: scheduleName,
                rrule: rruleWithTimes,
                dtstart: dtstart,
                notes: scheduleDescription,
                enabled: true
            )

            // Create schedule
            let createdSchedule = try await ScheduleService().createSchedule(
                id: schedule.id,
                profileId: profile.id,
                routineId: routineId,
                name: schedule.name,
                rrule: schedule.rrule,
                dtstart: ISO8601DateFormatter().string(from: schedule.dtstart),
                exdates: schedule.exdates,
                notes: schedule.notes,
                enabled: schedule.enabled
            )

            // Step 4: Associate actions with schedule
            if !createdActionIds.isEmpty {
                logger.info("Associating \(createdActionIds.count) actions with schedule")
                try await ScheduleService().replaceScheduleActions(
                    scheduleId: createdSchedule.id,
                    actionIds: createdActionIds
                )
            }

            // Success!
            logger.info("Successfully created routine and schedule")

            // Wait a moment to show success state
            try await Task.sleep(nanoseconds: 1_500_000_000)

            // Call completion handler with schedule ID
            await MainActor.run {
                onComplete(createdSchedule.id)
            }

            return true

        } catch {
            logger.error("Failed to create routine and schedule: \(error)")
            return false
        }
    }

    private func buildRRuleWithTimes(baseRRule: String, times: [Date]) -> String {
        guard !times.isEmpty else { return baseRRule }

        let calendar = Calendar.current

        // Extract hours and minutes from times
        let hours = times.map { calendar.component(.hour, from: $0) }
        let minutes = times.map { calendar.component(.minute, from: $0) }

        // Build BYHOUR and BYMINUTE clauses
        let byHour = "BYHOUR=" + hours.map(String.init).joined(separator: ",")
        let byMinute = "BYMINUTE=" + minutes.map(String.init).joined(separator: ",")

        // Remove existing BYHOUR and BYMINUTE if present
        var rrule = baseRRule
        rrule = rrule.replacingOccurrences(of: ";BYHOUR=[^;]+", with: "", options: .regularExpression)
        rrule = rrule.replacingOccurrences(of: ";BYMINUTE=[^;]+", with: "", options: .regularExpression)

        // Append new time constraints
        return "\(rrule);\(byHour);\(byMinute)"
    }
}

// MARK: - Wizard Steps

enum WizardStep: Int, CaseIterable {
    case selection = 0
    case customization = 1
    case review = 2

    var title: String {
        switch self {
        case .selection: return "Choose Template"
        case .customization: return "Customize"
        case .review: return "Review"
        }
    }
}

// MARK: - Preview

#Preview {
    ScheduleWizardView(
        routineViewModel: RoutineViewModel(),
        scheduleViewModel: ScheduleViewModel(),
        onComplete: { _ in },
        onCancel: {}
    )
    .environmentObject(AppState.shared)
    .frame(width: 800, height: 700)
}
