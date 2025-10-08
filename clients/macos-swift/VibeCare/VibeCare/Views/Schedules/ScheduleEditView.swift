@preconcurrency import OpenTelemetryApi
import SwiftUI

// MARK: - Recurrence Mode
enum RecurrenceMode {
  case ui
  case json
}

// MARK: - Template definitions
struct ScheduleTemplate: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let category: String
  let rruleJSON: String
  let icon: String

  static func == (lhs: ScheduleTemplate, rhs: ScheduleTemplate) -> Bool {
    lhs.name == rhs.name && lhs.category == rhs.category
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(category)
  }
}

// Predefined templates organized by category
struct ScheduleTemplates {
  static let all: [ScheduleTemplate] = [
    // One-Shot Events (use count=1 for one-time execution)
    ScheduleTemplate(
      name: "6pm Today", category: "One-Time",
      rruleJSON: #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "9am Tomorrow", category: "One-Time",
      rruleJSON: #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "2pm Next Sunday", category: "One-Time",
      rruleJSON: #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Next Monday", category: "One-Time",
      rruleJSON: #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),

    // Frequent (Minutes)
    ScheduleTemplate(
      name: "Every 5 minutes", category: "Minutes",
      rruleJSON: #"{"freq":"MINUTELY","interval":5,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 15 minutes", category: "Minutes",
      rruleJSON: #"{"freq":"MINUTELY","interval":15,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 20 minutes", category: "Minutes",
      rruleJSON: #"{"freq":"MINUTELY","interval":20,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 30 minutes", category: "Minutes",
      rruleJSON: #"{"freq":"MINUTELY","interval":30,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),

    // Hourly
    ScheduleTemplate(
      name: "Every Hour", category: "Hourly",
      rruleJSON: #"{"freq":"HOURLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 2 Hours", category: "Hourly",
      rruleJSON: #"{"freq":"HOURLY","interval":2,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 4 Hours", category: "Hourly",
      rruleJSON: #"{"freq":"HOURLY","interval":4,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "clock"
    ),

    // Daily
    ScheduleTemplate(
      name: "Daily", category: "Daily",
      rruleJSON: #"{"freq":"DAILY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "sun.max"
    ),
    ScheduleTemplate(
      name: "Weekdays", category: "Daily",
      rruleJSON: #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["MO","TU","WE","TH","FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Weekends", category: "Daily",
      rruleJSON: #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["SA","SU"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Daily at 9am", category: "Daily",
      rruleJSON: #"{"freq":"DAILY","interval":1,"byhour":[9],"byminute":[0],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "sun.max"
    ),

    // Weekly
    ScheduleTemplate(
      name: "Weekly", category: "Weekly",
      rruleJSON: #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "repeat"
    ),
    ScheduleTemplate(
      name: "Every Monday at 9 AM", category: "Weekly",
      rruleJSON: #"{"freq":"WEEKLY","interval":1,"byhour":[9],"byminute":[0],"byday":["MO"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "repeat"
    ),
    ScheduleTemplate(
      name: "Every Friday", category: "Weekly",
      rruleJSON: #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "repeat"
    ),

    // Monthly
    ScheduleTemplate(
      name: "Monthly", category: "Monthly",
      rruleJSON: #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "First of Month", category: "Monthly",
      rruleJSON: #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Last of Month", category: "Monthly",
      rruleJSON: #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[-1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),

    // One-time templates
    ScheduleTemplate(
      name: "Tomorrow at 9 AM", category: "Quick",
      rruleJSON: #"{"freq":"DAILY","interval":1,"count":1,"byhour":[9],"byminute":[0],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#,
      icon: "calendar"
    ),
  ]

  static var groupedTemplates: [String: [ScheduleTemplate]] {
    Dictionary(grouping: all, by: { $0.category })
  }

  static var quickTemplates: [ScheduleTemplate] {
    [
      all.first(where: { $0.name == "Every 20 minutes" }) ?? all[0],
      all.first(where: { $0.name == "Tomorrow at 9 AM" }) ?? all[1],
      all.first(where: { $0.name == "Every Monday at 9 AM" }) ?? all[2],
    ]
  }
}

struct ScheduleEditView: View {
  let routineId: String
  @ObservedObject var scheduleViewModel: ScheduleViewModel
  let isCreating: Bool
  let schedule: Schedule?
  let parentSpan: Span?
  let onDismiss: () -> Void

  // Static counter for tracking initialization sequence
  private static var initCounter: Int = 0
  private static let initCounterQueue = DispatchQueue(label: "init-counter")
  private let initSequenceNumber: Int

  // MARK: - State Variables
  @State private var scheduleName: String = ""
  @State private var notes: String = ""
  @State private var startDate: Date = {
    // Default to 5 minutes from now for new schedules
    let now = Date()
    return Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now
  }()
  @State private var enabled: Bool = true
  @State private var selectedPriority: Priority = .none

  // Recurrence state
  @State private var recurrenceMode: RecurrenceMode = .ui
  @State private var customRRule: String = ""
  @State private var selectedFrequency: RRule.Frequency = .minutely
  @State private var intervalValue: Int = 20
  @State private var endDate: Date? = nil
  @State private var isOneTimeEvent: Bool = false

  // Granular recurrence controls
  @State private var selectedWeekdays: Set<String> = []
  @State private var selectedMonthDays: Set<Int> = []
  @State private var selectedMonths: Set<Int> = []
  @State private var atTime: Date? = nil

  // UI state
  @State private var selectedTemplate: ScheduleTemplate?
  @State private var validationError: String?

  init(
    routineId: String,
    scheduleViewModel: ScheduleViewModel,
    schedule: Schedule? = nil,
    isCreating: Bool = true,
    parentSpan: Span? = nil,
    onDismiss: @escaping () -> Void
  ) {
    let initStartTime = Date()

    // Track initialization sequence
    self.initSequenceNumber = Self.initCounterQueue.sync {
      Self.initCounter += 1
      return Self.initCounter
    }

    // Create init span
    let initSpan: Span
    if let parentSpan = parentSpan {
      initSpan = OTELManager.shared.traceChildViewInit("ScheduleEditView", parent: parentSpan)
    } else {
      initSpan = OTELManager.shared.traceViewInit("ScheduleEditView")
    }

    initSpan.setAttribute(key: "routine.id", value: AttributeValue.string(routineId))
    initSpan.setAttribute(key: "is_creating", value: AttributeValue.bool(isCreating))
    initSpan.setAttribute(key: "has_schedule", value: AttributeValue.bool(schedule != nil))

    defer {
      let initEndTime = Date()
      let initDuration = initEndTime.timeIntervalSince(initStartTime)
      initSpan.setAttribute(
        key: "init_duration_ms", value: AttributeValue.double(initDuration * 1000))
      initSpan.status = .ok
      initSpan.end()
    }

    self.routineId = routineId
    self.scheduleViewModel = scheduleViewModel
    self.schedule = schedule
    self.isCreating = isCreating
    self.parentSpan = parentSpan
    self.onDismiss = onDismiss

    // Initialize state from existing schedule or defaults
    if let schedule = schedule {
      self._scheduleName = State(initialValue: schedule.name)
      self._customRRule = State(initialValue: schedule.recurrenceJSON)
      self._startDate = State(initialValue: schedule.dtstart)
      self._notes = State(initialValue: schedule.notes)
      self._enabled = State(initialValue: schedule.enabled)
      self._selectedPriority = State(initialValue: schedule.priority)
      self._selectedTemplate = State(initialValue: nil)

      // Parse RRule to populate UI fields
      if let rrule = try? RRule.fromJSON(schedule.recurrenceJSON) {
        self._selectedFrequency = State(initialValue: rrule.freq)
        self._intervalValue = State(initialValue: rrule.interval)
        self._endDate = State(initialValue: rrule.until)
        self._isOneTimeEvent = State(initialValue: rrule.count == 1)
      }
    } else {
      let firstTemplate = ScheduleTemplates.quickTemplates.first
      self._selectedTemplate = State(initialValue: firstTemplate)
      self._customRRule = State(initialValue: firstTemplate?.rruleJSON ?? "{}")

      if let firstTemplate = firstTemplate {
        self._scheduleName = State(initialValue: firstTemplate.name)
      }
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          // Title and Notes
          titleAndNotesSection

          // Date & Time
          dateAndTimeSection

          // Quick Templates
          quickTemplatesSection

          // Recurrence (only show for recurring events)
          if !isOneTimeEvent {
            recurrenceSection
          }

          // Priority
          prioritySection

          // Bottom spacing
          Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
      }
      .frame(minWidth: 650, minHeight: 700)
      .navigationTitle(isCreating ? "Add Schedule" : "Edit Schedule")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onDismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 8) {
            Text("Enabled")
              .font(.subheadline)
            Toggle("", isOn: $enabled)
              .toggleStyle(.switch)
              .labelsHidden()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(isCreating ? "Create Task" : "Save") {
            saveSchedule()
          }
          .disabled(scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .buttonStyle(.borderedProminent)
        }
      }
      .withTracing(viewName: "ScheduleEditView", parentSpan: parentSpan)
    }
  }

  // MARK: - Title and Notes Section
  private var titleAndNotesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Task title", text: $scheduleName)
        .font(.title2)
        .fontWeight(.semibold)
        .textFieldStyle(.plain)

      TextField("Add notes...", text: $notes, axis: .vertical)
        .font(.body)
        .foregroundColor(.secondary)
        .textFieldStyle(.plain)
        .lineLimit(2...6)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)

      if let error = validationError {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
      }
    }
  }

  // MARK: - Date & Time Section
  private var dateAndTimeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Date & Time")
        .font(.headline)
        .fontWeight(.semibold)

      HStack(spacing: 12) {
        // Date Picker Button
        HStack(spacing: 8) {
          Image(systemName: "calendar")
            .foregroundColor(.secondary)
            .font(.body)

          DatePicker(
            "",
            selection: $startDate,
            displayedComponents: [.date]
          )
          .datePickerStyle(.compact)
          .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)

        // Time Picker Button
        HStack(spacing: 8) {
          Image(systemName: "clock")
            .foregroundColor(.secondary)
            .font(.body)

          DatePicker(
            "",
            selection: $startDate,
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
      }
    }
  }

  // MARK: - Quick Templates Section
  private var quickTemplatesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Quick templates")
        .font(.subheadline)
        .foregroundColor(.secondary)

      HStack(spacing: 12) {
        ForEach(ScheduleTemplates.quickTemplates, id: \.name) { template in
          QuickTemplateButton(
            template: template,
            isSelected: selectedTemplate?.name == template.name,
            action: {
              selectTemplate(template)
            }
          )
        }
        Spacer()
      }
    }
  }

  // MARK: - Recurrence Section
  private var recurrenceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Recurrence")
          .font(.headline)
          .fontWeight(.semibold)

        Spacer()

        Button(action: {
          withAnimation(.easeInOut(duration: 0.2)) {
            toggleRecurrenceMode()
          }
        }) {
          HStack(spacing: 4) {
            Image(systemName: "chevron.left.slash.chevron.right")
              .font(.caption)
            Text(recurrenceMode == .ui ? "JSON Mode" : "UI Mode")
              .font(.subheadline)
          }
          .foregroundColor(.accentColor)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.accentColor.opacity(0.1))
          .cornerRadius(8)
        }
        .buttonStyle(.plain)
      }

      if recurrenceMode == .ui {
        uiModeRecurrenceSection
      } else {
        jsonModeRecurrenceSection
      }
    }
  }

  // MARK: - UI Mode Recurrence
  private var uiModeRecurrenceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Text("Repeat every")
          .font(.body)

        TextField("", value: $intervalValue, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 80)
          .multilineTextAlignment(.center)

        Picker("", selection: $selectedFrequency) {
          Text("Minutes").tag(RRule.Frequency.minutely)
          Text("Hours").tag(RRule.Frequency.hourly)
          Text("Days").tag(RRule.Frequency.daily)
          Text("Weekly").tag(RRule.Frequency.weekly)
          Text("Monthly").tag(RRule.Frequency.monthly)
          Text("Yearly").tag(RRule.Frequency.yearly)
        }
        .pickerStyle(.menu)
        .frame(width: 140)

        Spacer()
      }

      // Frequency-specific controls
      switch selectedFrequency {
      case .weekly:
        weeklyControls
      case .monthly:
        monthlyControls
      case .yearly:
        yearlyControls
      case .minutely, .hourly, .daily:
        atTimeControl
      }

      // End Date Section with left accent
      VStack(alignment: .leading, spacing: 8) {
        Text("End date (optional)")
          .font(.subheadline)
          .foregroundColor(.secondary)

        HStack {
          Image(systemName: "calendar")
            .foregroundColor(.secondary)

          if let endDate = endDate {
            Text(endDate, style: .date)
            Spacer()
            Button("Clear") {
              self.endDate = nil
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
          } else {
            Text("No end date")
              .foregroundColor(.secondary)
            Spacer()
            Button("Set Date") {
              self.endDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
          }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
      }
      .padding(.leading, 4)
      .overlay(
        Rectangle()
          .fill(Color.accentColor)
          .frame(width: 3)
          .cornerRadius(1.5),
        alignment: .leading
      )
    }
    .onChange(of: selectedFrequency) { _, _ in syncUIToJSON() }
    .onChange(of: intervalValue) { _, _ in syncUIToJSON() }
    .onChange(of: endDate) { _, _ in syncUIToJSON() }
    .onChange(of: selectedWeekdays) { _, _ in syncUIToJSON() }
    .onChange(of: selectedMonthDays) { _, _ in syncUIToJSON() }
    .onChange(of: selectedMonths) { _, _ in syncUIToJSON() }
    .onChange(of: atTime) { _, _ in syncUIToJSON() }
  }

  // MARK: - Frequency-Specific Controls
  private var weeklyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("On days")
        .font(.subheadline)
        .fontWeight(.medium)

      WeekdaySelector(selectedDays: $selectedWeekdays)

      if let atTime = atTime {
        Text("At time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker("", selection: Binding(
          get: { atTime },
          set: { self.atTime = $0 }
        ), displayedComponents: [.hourAndMinute])
          .datePickerStyle(.compact)
          .labelsHidden()
      } else {
        Button("Add time") {
          self.atTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
      }
    }
    .padding(.leading, 4)
    .overlay(
      Rectangle()
        .fill(Color.accentColor)
        .frame(width: 3)
        .cornerRadius(1.5),
      alignment: .leading
    )
  }

  private var monthlyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("On days")
        .font(.subheadline)
        .fontWeight(.medium)

      MonthDaySelector(selectedDays: $selectedMonthDays)

      if let atTime = atTime {
        Text("At time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker("", selection: Binding(
          get: { atTime },
          set: { self.atTime = $0 }
        ), displayedComponents: [.hourAndMinute])
          .datePickerStyle(.compact)
          .labelsHidden()
      } else {
        Button("Add time") {
          self.atTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
      }
    }
    .padding(.leading, 4)
    .overlay(
      Rectangle()
        .fill(Color.accentColor)
        .frame(width: 3)
        .cornerRadius(1.5),
      alignment: .leading
    )
  }

  private var yearlyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("In months")
        .font(.subheadline)
        .fontWeight(.medium)

      MonthSelector(selectedMonths: $selectedMonths)

      if let atTime = atTime {
        Text("At time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker("", selection: Binding(
          get: { atTime },
          set: { self.atTime = $0 }
        ), displayedComponents: [.hourAndMinute])
          .datePickerStyle(.compact)
          .labelsHidden()
      } else {
        Button("Add time") {
          self.atTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
      }
    }
    .padding(.leading, 4)
    .overlay(
      Rectangle()
        .fill(Color.accentColor)
        .frame(width: 3)
        .cornerRadius(1.5),
      alignment: .leading
    )
  }

  private var atTimeControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("At time")
        .font(.subheadline)
        .fontWeight(.medium)

      if let atTime = atTime {
        HStack {
          DatePicker("", selection: Binding(
            get: { atTime },
            set: { self.atTime = $0 }
          ), displayedComponents: [.hourAndMinute])
            .datePickerStyle(.compact)
            .labelsHidden()

          Spacer()

          Button("Remove") {
            self.atTime = nil
          }
          .buttonStyle(.plain)
          .foregroundColor(.red)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
      } else {
        Button(action: {
          self.atTime = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        }) {
          HStack {
            Image(systemName: "clock")
              .foregroundColor(.secondary)
            Text("Add specific time")
              .foregroundColor(.accentColor)
            Spacer()
          }
          .padding(12)
          .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
          .cornerRadius(8)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.leading, 4)
    .overlay(
      Rectangle()
        .fill(Color.accentColor)
        .frame(width: 3)
        .cornerRadius(1.5),
      alignment: .leading
    )
  }

  // MARK: - JSON Mode Recurrence
  private var jsonModeRecurrenceSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $customRRule)
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .frame(minHeight: 200, maxHeight: 300)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 2)
        )
        .onChange(of: customRRule) { _, _ in syncJSONToUI() }
    }
  }

  // MARK: - Priority Section
  private var prioritySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Priority")
        .font(.headline)
        .fontWeight(.semibold)

      HStack(spacing: 12) {
        ForEach(Priority.allCases, id: \.self) { priority in
          PriorityButton(
            priority: priority,
            isSelected: selectedPriority == priority,
            action: {
              selectedPriority = priority
            }
          )
        }
      }
    }
  }

  // MARK: - Helper Methods
  private func selectTemplate(_ template: ScheduleTemplate) {
    TraceableAction(actionName: "quick_template_select", component: "template_grid").execute {
      let wasOneTimeEvent = isOneTimeEvent
      selectedTemplate = template
      customRRule = template.rruleJSON
      if scheduleName.isEmpty || scheduleName == selectedTemplate?.name {
        scheduleName = template.name
      }

      // Check if this is a one-time event and parse RRule
      if let rrule = try? RRule.fromJSON(template.rruleJSON) {
        isOneTimeEvent = (rrule.count == 1)

        // Sync time from template for one-time events
        if isOneTimeEvent {
          syncTimeFromTemplate(rrule: rrule, templateName: template.name)
        } else {
          // If switching from one-time to recurring, reset time to 5 mins from now
          if wasOneTimeEvent && isCreating {
            startDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
          }
          syncJSONToUI()
        }
      }
    }
  }

  private func syncTimeFromTemplate(rrule: RRule, templateName: String) {
    let calendar = Calendar.current
    var targetDate = Date()

    // Handle specific one-time templates
    if templateName.contains("Tomorrow") {
      // Set to tomorrow
      targetDate = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    } else if templateName.contains("Next Monday") {
      // Set to next Monday
      let today = Date()
      let weekday = calendar.component(.weekday, from: today)
      let daysUntilMonday = (2 - weekday + 7) % 7
      targetDate = calendar.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday, to: today) ?? Date()
    } else if templateName.contains("Next Sunday") {
      // Set to next Sunday
      let today = Date()
      let weekday = calendar.component(.weekday, from: today)
      let daysUntilSunday = (1 - weekday + 7) % 7
      targetDate = calendar.date(byAdding: .day, value: daysUntilSunday == 0 ? 7 : daysUntilSunday, to: today) ?? Date()
    } else {
      // Today at specific time
      targetDate = Date()
    }

    // Apply time from RRule if specified
    if !rrule.byhour.isEmpty, let hour = rrule.byhour.first {
      let minute = rrule.byminute.first ?? 0
      if let dateWithTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: targetDate) {
        startDate = dateWithTime
        return
      }
    }

    // Default: 5 minutes from now
    startDate = calendar.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
  }

  private func toggleRecurrenceMode() {
    if recurrenceMode == .ui {
      syncUIToJSON()
      recurrenceMode = .json
    } else {
      syncJSONToUI()
      recurrenceMode = .ui
    }
  }

  private func syncUIToJSON() {
    let calendar = Calendar.current
    var byhour: [Int] = []
    var byminute: [Int] = []

    // Extract time if set
    if let atTime = atTime {
      byhour = [calendar.component(.hour, from: atTime)]
      byminute = [calendar.component(.minute, from: atTime)]
    }

    let rrule = RRule(
      freq: selectedFrequency,
      interval: intervalValue,
      byhour: byhour,
      byminute: byminute,
      byday: Array(selectedWeekdays),
      bymonthday: Array(selectedMonthDays).sorted(),
      bymonth: Array(selectedMonths).sorted(),
      until: endDate,
      count: isOneTimeEvent ? 1 : nil
    )
    customRRule = (try? rrule.toJSON()) ?? customRRule
  }

  private func syncJSONToUI() {
    if let rrule = try? RRule.fromJSON(customRRule) {
      selectedFrequency = rrule.freq
      intervalValue = rrule.interval
      endDate = rrule.until
      isOneTimeEvent = (rrule.count == 1)

      // Parse weekdays
      selectedWeekdays = Set(rrule.byday)

      // Parse month days
      selectedMonthDays = Set(rrule.bymonthday)

      // Parse months
      selectedMonths = Set(rrule.bymonth)

      // Parse time
      if !rrule.byhour.isEmpty, let hour = rrule.byhour.first {
        let minute = rrule.byminute.first ?? 0
        atTime = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
      } else {
        atTime = nil
      }
    }
  }

  // MARK: - Actions
  private func saveSchedule() {
    Task { @MainActor in
      let trimmedName = scheduleName.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !trimmedName.isEmpty else {
        return
      }

      guard !customRRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        validationError = "RRule JSON cannot be empty"
        return
      }

      validationError = nil

      if isCreating {
        await scheduleViewModel.createSchedule(
          routineId: routineId,
          name: trimmedName,
          recurrenceJSON: customRRule,
          dtstart: startDate,
          notes: trimmedNotes,
          enabled: enabled,
          priority: selectedPriority
        )
      } else if let schedule = schedule {
        var updatedSchedule = schedule
        updatedSchedule.name = trimmedName
        updatedSchedule.recurrenceJSON = customRRule
        updatedSchedule.dtstart = startDate
        updatedSchedule.notes = trimmedNotes
        updatedSchedule.enabled = enabled
        updatedSchedule.priority = selectedPriority

        await scheduleViewModel.updateSchedule(updatedSchedule)
      }

      if let parentSpan = parentSpan {
        parentSpan.status = .ok
        parentSpan.end()
      }

      onDismiss()
    }
  }
}

// MARK: - Quick Template Button Component
struct QuickTemplateButton: View {
  let template: ScheduleTemplate
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: template.icon)
          .font(.caption)
        Text(template.name)
          .font(.subheadline)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minWidth: 150)
      .background(
        isSelected
          ? Color.accentColor
          : Color(NSColor.controlBackgroundColor)
      )
      .foregroundColor(isSelected ? .white : .primary)
      .cornerRadius(20)
      .overlay(
        RoundedRectangle(cornerRadius: 20)
          .stroke(
            isSelected ? Color.clear : Color.secondary.opacity(0.3),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Priority Button Component
struct PriorityButton: View {
  let priority: Priority
  let isSelected: Bool
  let action: () -> Void

  private var borderColor: Color {
    switch priority {
    case .none: return .gray
    case .low: return .green
    case .medium: return .orange
    case .high: return .red
    }
  }

  private var textColor: Color {
    if isSelected {
      return .white
    }
    switch priority {
    case .none: return .primary
    case .low: return .green
    case .medium: return .orange
    case .high: return .red
    }
  }

  var body: some View {
    Button(action: action) {
      Text(priority.displayName)
        .font(.subheadline)
        .fontWeight(.medium)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
          isSelected ? borderColor : Color.clear
        )
        .foregroundColor(textColor)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(borderColor, lineWidth: 1.5)
        )
        .cornerRadius(8)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Weekday Selector Component
struct WeekdaySelector: View {
  @Binding var selectedDays: Set<String>

  private let weekdays: [(short: String, full: String)] = [
    ("S", "SU"),
    ("M", "MO"),
    ("T", "TU"),
    ("W", "WE"),
    ("T", "TH"),
    ("F", "FR"),
    ("S", "SA")
  ]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
        Button(action: {
          if selectedDays.contains(day.full) {
            selectedDays.remove(day.full)
          } else {
            selectedDays.insert(day.full)
          }
        }) {
          Text(day.short)
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(width: 40, height: 40)
            .background(
              selectedDays.contains(day.full)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedDays.contains(day.full) ? .white : .primary)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Month Day Selector Component
struct MonthDaySelector: View {
  @Binding var selectedDays: Set<Int>

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...31, id: \.self) { day in
        Button(action: {
          if selectedDays.contains(day) {
            selectedDays.remove(day)
          } else {
            selectedDays.insert(day)
          }
        }) {
          Text("\(day)")
            .font(.caption)
            .fontWeight(.medium)
            .frame(width: 36, height: 36)
            .background(
              selectedDays.contains(day)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedDays.contains(day) ? .white : .primary)
            .cornerRadius(18)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Month Selector Component
struct MonthSelector: View {
  @Binding var selectedMonths: Set<Int>

  private let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...12, id: \.self) { month in
        Button(action: {
          if selectedMonths.contains(month) {
            selectedMonths.remove(month)
          } else {
            selectedMonths.insert(month)
          }
        }) {
          Text(months[month - 1])
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
              selectedMonths.contains(month)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedMonths.contains(month) ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Preview
#Preview {
  ScheduleEditView(
    routineId: "preview-routine",
    scheduleViewModel: ScheduleViewModel(),
    isCreating: true
  ) {
    // Dismiss action
  }
  .frame(width: 700, height: 800)
}
