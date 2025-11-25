import SwiftUI

struct TemplateCustomizationView: View {
  let template: RoutineScheduleTemplate
  @Binding var routineName: String
  @Binding var scheduleName: String
  @Binding var scheduleDescription: String
  @Binding var routineIcon: String
  @Binding var routineColor: String
  @Binding var times: [Date]
  @Binding var actions: [ActionTemplate]
  @Binding var selectedRoutineId: String?  // Track if user selected existing routine

  @ObservedObject var routineViewModel: RoutineViewModel

  let onBack: () -> Void
  let onNext: () -> Void

  @State private var expandedSection: String? = "times"
  @State private var showingIconPicker = false
  @StateObject private var iconManager = SVGIconManager.shared

  // Inline editing states
  @State private var isEditingRoutineName = false
  @State private var isEditingScheduleName = false
  @State private var isEditingDescription = false
  @FocusState private var routineNameFocused: Bool
  @FocusState private var scheduleNameFocused: Bool
  @FocusState private var descriptionFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // Header
      headerView

      Divider()

      // Content
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Large editable template preview card
          templatePreviewCard

          Divider()

          // Schedule times section
          scheduleTimesSection

          Divider()

          // Actions section
          actionsSection
        }
        .padding(20)
      }

      Divider()

      // Footer
      footerView
    }
    .frame(minWidth: 700, minHeight: 600)
  }

  // MARK: - Header

  private var headerView: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Customize Your Routine")
          .font(.title2)
          .fontWeight(.semibold)

        Text("Adjust the details to match your needs")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  // MARK: - Template Preview Card

  private var templatePreviewCard: some View {
    VStack(spacing: 16) {
      // Large icon - tappable for picker
      Button {
        showingIconPicker = true
      } label: {
        ZStack {
          TemplateIconView(
            iconId: routineIcon,
            backgroundColor: colorFromString(routineColor).opacity(0.15),
            size: 80
          )

          // Edit hint on hover
          Image(systemName: "pencil.circle.fill")
            .font(.system(size: 20))
            .foregroundColor(.accentColor)
            .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
            .offset(x: 30, y: 30)
        }
      }
      .buttonStyle(.plain)
      .help("Click to change icon")
      .popover(isPresented: $showingIconPicker) {
        SVGIconPickerView(
          iconManager: iconManager,
          selectedIconId: .constant(routineIcon.isEmpty ? nil : routineIcon),
          onSelect: { icon in
            routineIcon = icon.id
          },
          onDismiss: {
            showingIconPicker = false
          }
        )
      }

      // Editable Schedule Name
      editableScheduleName

      // Editable Routine Name with dropdown
      editableRoutineNameWithDropdown

      // Editable Description
      editableDescriptionField

      // Frequency badge
      HStack(spacing: 6) {
        Image(systemName: "clock")
          .font(.caption)
        Text(frequencyDescription)
          .font(.caption)
      }
      .foregroundColor(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.1))
      .clipShape(Capsule())

      // Color picker row
      inlineColorPicker
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(colorFromString(routineColor), lineWidth: 2)
    )
  }

  // MARK: - Inline Color Picker

  private var inlineColorPicker: some View {
    let colors = ["blue", "green", "red", "orange", "purple", "pink", "yellow", "gray"]

    return HStack(spacing: 12) {
      ForEach(colors, id: \.self) { color in
        Button {
          routineColor = color
        } label: {
          Circle()
            .fill(colorFromString(color))
            .frame(width: 28, height: 28)
            .overlay(
              Circle()
                .stroke(Color.white, lineWidth: routineColor == color ? 3 : 0)
            )
            .overlay(
              Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(routineColor == color ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2), value: routineColor)
      }
    }
    .padding(.top, 8)
  }

  // MARK: - Schedule Times Section

  private var scheduleTimesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        title: "Schedule Times",
        icon: "clock",
        sectionId: "times"
      )

      timePickersList
    }
  }

  private var timePickersList: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(times.enumerated()), id: \.offset) { index, time in
        timePickerRow(index: index, time: time)
      }

      // Add time button
      Button {
        withAnimation {
          times.append(Date())
        }
      } label: {
        HStack {
          Image(systemName: "plus.circle.fill")
          Text("Add Another Time")
            .font(.subheadline)
        }
      }
      .buttonStyle(.plain)
      .foregroundColor(.accentColor)
    }
  }

  private func timePickerRow(index: Int, time: Date) -> some View {
    HStack {
      DatePicker(
        "Time \(index + 1)",
        selection: Binding(
          get: { times[index] },
          set: { times[index] = $0 }
        ),
        displayedComponents: .hourAndMinute
      )
      .labelsHidden()

      Spacer()

      // Remove time button
      if times.count > 1 {
        Button {
          withAnimation {
            _ = times.remove(at: index)
          }
        } label: {
          Image(systemName: "minus.circle.fill")
            .foregroundColor(.red)
        }
        .buttonStyle(.plain)
        .help("Remove this time")
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Actions Section

  private var actionsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        title: "Actions",
        icon: "bolt.fill",
        sectionId: "actions"
      )

      if actions.isEmpty {
        emptyActionsView
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
            actionRow(action: action, index: index)
          }
        }
      }

      // Add action button
      addActionButton
    }
  }

  // MARK: - Section Header

  private func sectionHeader(title: String, icon: String, sectionId: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.headline)
        .foregroundColor(.accentColor)

      Text(title)
        .font(.headline)
        .fontWeight(.semibold)

      Spacer()
    }
  }

  // MARK: - Action Row

  private func actionRow(action: ActionTemplate, index: Int) -> some View {
    HStack(spacing: 12) {
      // Action icon
      Image(systemName: actionIconName(action.type))
        .font(.system(size: 16))
        .foregroundColor(.accentColor)
        .frame(width: 24, height: 24)

      // Action info
      VStack(alignment: .leading, spacing: 2) {
        Text(action.name)
          .font(.subheadline)
          .fontWeight(.medium)

        Text(actionTypeLabel(action.type))
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()

      // Remove button
      Button {
        withAnimation {
          let _ = actions.remove(at: index)
        }
      } label: {
        Image(systemName: "trash")
          .foregroundColor(.red)
      }
      .buttonStyle(.plain)
      .help("Remove action")
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  // MARK: - Empty Actions View

  private var emptyActionsView: some View {
    VStack(spacing: 8) {
      Image(systemName: "bolt.slash")
        .font(.system(size: 32))
        .foregroundColor(.secondary)

      Text("No actions configured")
        .font(.subheadline)
        .foregroundColor(.secondary)

      Text("Add actions to make this schedule do something")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
    )
  }

  // MARK: - Add Action Button

  private var addActionButton: some View {
    Menu {
      Button {
        addNotificationAction()
      } label: {
        Label("Notification", systemImage: "bell.fill")
      }

      Button {
        addLinkAction()
      } label: {
        Label("Open Link", systemImage: "link")
      }

      Button {
        addLogAction()
      } label: {
        Label("Log Entry", systemImage: "text.alignleft")
      }
    } label: {
      HStack {
        Image(systemName: "plus.circle.fill")
        Text("Add Action")
          .font(.subheadline)
      }
    }
    .buttonStyle(.plain)
    .foregroundColor(.accentColor)
  }

  // MARK: - Footer

  private var footerView: some View {
    HStack {
      Button("Back") {
        onBack()
      }

      Spacer()

      Button("Review & Create") {
        onNext()
      }
      .keyboardShortcut(.return, modifiers: [])
      .buttonStyle(.borderedProminent)
      .disabled(
        routineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(20)
  }

  // MARK: - Color Helper

  private func colorFromString(_ colorName: String) -> Color {
    switch colorName.lowercased() {
    case "blue": return .blue
    case "red": return .red
    case "green": return .green
    case "orange": return .orange
    case "purple": return .purple
    case "pink": return .pink
    case "yellow": return .yellow
    case "gray", "grey": return .gray
    case "brown": return .brown
    case "cyan": return .cyan
    case "indigo": return .indigo
    case "mint": return .mint
    case "teal": return .teal
    default: return .blue
    }
  }

  // MARK: - Editable Field Views

  private var editableRoutineNameWithDropdown: some View {
    HStack(spacing: 8) {
      if isEditingRoutineName {
        TextField("Routine Name", text: $routineName)
          .font(.headline)
          .fontWeight(.semibold)
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .focused($routineNameFocused)
          .onSubmit {
            isEditingRoutineName = false
          }
          .onKeyPress(.escape) {
            isEditingRoutineName = false
            return .handled
          }
          .onChange(of: routineName) { _, newValue in
            // Clear selectedRoutineId if user edits name to differ from selected routine
            if let existingId = selectedRoutineId,
              let selectedRoutine = routineViewModel.routines.first(where: { $0.id == existingId }),
              selectedRoutine.name != newValue
            {
              selectedRoutineId = nil
            }
          }
      } else {
        Text(routineName.isEmpty ? "Routine Name" : routineName)
          .font(.headline)
          .fontWeight(.semibold)
          .foregroundColor(routineName.isEmpty ? .secondary : .primary)
          .contentShape(Rectangle())
          .onTapGesture(count: 2) {
            isEditingRoutineName = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              routineNameFocused = true
            }
          }
          .help("Double-click to edit")
      }

      // Dropdown for existing routines - only show if routines exist
      if !routineViewModel.routines.isEmpty {
        routineDropdownMenu
      }
    }
  }

  private var routineDropdownMenu: some View {
    Menu {
      ForEach(routineViewModel.routines) { routine in
        Button {
          routineName = routine.name
          routineIcon = routine.iconName
          routineColor = routine.color
          selectedRoutineId = routine.id
        } label: {
          Label(routine.name, systemImage: routine.iconName)
        }
      }
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Choose from existing routines")
  }

  private var editableScheduleName: some View {
    Group {
      if isEditingScheduleName {
        TextField("Schedule Name", text: $scheduleName)
          .font(.title2)
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .focused($scheduleNameFocused)
          .onSubmit {
            isEditingScheduleName = false
          }
          .onKeyPress(.escape) {
            isEditingScheduleName = false
            return .handled
          }
      } else {
        Text(scheduleName.isEmpty ? "Schedule Name" : scheduleName)
          .font(.title2)
          .foregroundColor(scheduleName.isEmpty ? .secondary : .primary)
          .contentShape(Rectangle())
          .onTapGesture(count: 2) {
            isEditingScheduleName = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              scheduleNameFocused = true
            }
          }
          .help("Double-click to edit")
      }
    }
  }

  private var editableDescriptionField: some View {
    Group {
      if isEditingDescription {
        TextField("Add description...", text: $scheduleDescription)
          .font(.subheadline)
          .textFieldStyle(.plain)
          .multilineTextAlignment(.center)
          .focused($descriptionFocused)
          .onSubmit {
            isEditingDescription = false
          }
          .onKeyPress(.escape) {
            isEditingDescription = false
            return .handled
          }
      } else {
        Text(scheduleDescription.isEmpty ? "Add description..." : scheduleDescription)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .italic(scheduleDescription.isEmpty)
          .contentShape(Rectangle())
          .onTapGesture(count: 2) {
            isEditingDescription = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              descriptionFocused = true
            }
          }
          .help("Double-click to edit")
      }
    }
  }

  // MARK: - Helpers

  private var frequencyDescription: String {
    if times.count == 1 {
      return "Once per occurrence"
    } else {
      return "\(times.count) times per occurrence"
    }
  }

  private func actionIconName(_ type: ActionType) -> String {
    switch type {
    case .notification: return "bell.fill"
    case .openLink: return "link"
    case .sendEmail: return "envelope.fill"
    case .runScript: return "terminal.fill"
    case .playSound: return "speaker.wave.2.fill"
    case .systemCommand: return "command"
    case .apiCall: return "network"
    case .logEntry: return "text.alignleft"
    }
  }

  private func actionTypeLabel(_ type: ActionType) -> String {
    switch type {
    case .notification: return "Show notification"
    case .openLink: return "Open URL"
    case .sendEmail: return "Send email"
    case .runScript: return "Run script"
    case .playSound: return "Play sound"
    case .systemCommand: return "System command"
    case .apiCall: return "API call"
    case .logEntry: return "Log message"
    }
  }

  // MARK: - Action Creation

  private func addNotificationAction() {
    let newAction = ActionTemplate(
      type: .notification,
      name: "Notification",
      parameters: [
        "title": "\(routineName) Reminder",
        "body": "Time for: \(scheduleName)",
        "sound": "default",
      ]
    )
    withAnimation {
      actions.append(newAction)
    }
  }

  private func addLinkAction() {
    let newAction = ActionTemplate(
      type: .openLink,
      name: "Open Link",
      parameters: [
        "url": "https://example.com"
      ]
    )
    withAnimation {
      actions.append(newAction)
    }
  }

  private func addLogAction() {
    let newAction = ActionTemplate(
      type: .logEntry,
      name: "Log Entry",
      parameters: [
        "message": "\(routineName) executed at {time}"
      ]
    )
    withAnimation {
      actions.append(newAction)
    }
  }
}

// MARK: - Preview

#Preview {
  let template =
    RoutineScheduleTemplate.allTemplates.first
    ?? RoutineScheduleTemplate(
      id: "preview",
      category: .daily,
      routineName: "Preview Routine",
      routineIcon: "star.fill",
      routineColor: "blue",
      scheduleName: "Preview Schedule",
      rruleString: "FREQ=DAILY",
      defaultTimes: [TimeComponents(hour: 9, minute: 0)]
    )

  TemplateCustomizationView(
    template: template,
    routineName: .constant(template.routineName),
    scheduleName: .constant(template.scheduleName),
    scheduleDescription: .constant(template.scheduleDescription),
    routineIcon: .constant(template.routineIcon),
    routineColor: .constant(template.routineColor),
    times: .constant(template.defaultTimes.map { $0.toDate() }),
    actions: .constant(template.suggestedActions),
    selectedRoutineId: .constant(nil),
    routineViewModel: RoutineViewModel(),
    onBack: {},
    onNext: {}
  )
}
