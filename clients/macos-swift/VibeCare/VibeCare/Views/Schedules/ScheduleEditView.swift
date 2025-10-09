@preconcurrency import OpenTelemetryApi
import SwiftUI

// MARK: - Recurrence Mode
enum RecurrenceMode {
  case ui
  case rrule  // RFC 5545 RRule string mode
}

// MARK: - RRule Examples
struct RRuleExample: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let rruleString: String
  let description: String

  static let examples: [RRuleExample] = [
    // Daily routines
    RRuleExample(
      name: "Walk the pets",
      rruleString: "FREQ=DAILY;BYHOUR=19;BYMINUTE=0",
      description: "Daily at 7:00 PM"
    ),
    RRuleExample(
      name: "Pushups 3x/day",
      rruleString: "FREQ=DAILY;BYHOUR=7,12,19;BYMINUTE=0",
      description: "Every day at 7am, 12pm, and 7pm"
    ),
    RRuleExample(
      name: "Pick up kids",
      rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=16;BYMINUTE=0",
      description: "Weekdays at 4:00 PM"
    ),

    // Weekly routines
    RRuleExample(
      name: "Check mailbox",
      rruleString: "FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=0",
      description: "Every Friday at 7:00 AM"
    ),
    RRuleExample(
      name: "Take out trash",
      rruleString: "FREQ=WEEKLY;BYDAY=TH;BYHOUR=20;BYMINUTE=0",
      description: "Every Thursday at 8:00 PM"
    ),
    RRuleExample(
      name: "Security training",
      rruleString: "FREQ=WEEKLY;BYDAY=TU,TH;BYHOUR=14;BYMINUTE=0",
      description: "Tuesday and Thursday at 2:00 PM"
    ),
    RRuleExample(
      name: "Groceries",
      rruleString: "FREQ=WEEKLY;BYDAY=SA;BYHOUR=14;BYMINUTE=0",
      description: "Every Saturday at 2:00 PM"
    ),
    RRuleExample(
      name: "Bathroom cleanup",
      rruleString: "FREQ=WEEKLY;BYDAY=WE,SA;BYHOUR=15;BYMINUTE=0",
      description: "Wednesday and Saturday at 3:00 PM"
    ),

    // Monthly/Yearly
    RRuleExample(
      name: "Rent reminder",
      rruleString: "FREQ=MONTHLY;BYDAY=-1MO;BYHOUR=9;BYMINUTE=0",
      description: "Last Monday of every month at 9:00 AM"
    ),
    RRuleExample(
      name: "Birthday",
      rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0",
      description: "January 1st every year"
    ),
    RRuleExample(
      name: "Anniversary",
      rruleString: "FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=3;BYHOUR=9;BYMINUTE=0",
      description: "Week before Oct 10 (Oct 3) every year"
    ),
    RRuleExample(
      name: "Declutter clothes",
      rruleString: "FREQ=YEARLY;BYMONTH=7;BYMONTHDAY=1;BYHOUR=10;BYMINUTE=0",
      description: "Annually on July 1st"
    )
  ]
}

// MARK: - Template definitions
struct ScheduleTemplate: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let category: String
  let rruleString: String  // RFC 5545 RRule string
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
    // One-Shot Events (no recurrence, just use dtstart time)
    ScheduleTemplate(
      name: "6pm Today", category: "One-Time",
      rruleString: "",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "9am Tomorrow", category: "One-Time",
      rruleString: "",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "2pm Next Sunday", category: "One-Time",
      rruleString: "",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Next Monday", category: "One-Time",
      rruleString: "",
      icon: "calendar"
    ),

    // Frequent (Minutes)
    ScheduleTemplate(
      name: "Every 5 minutes", category: "Minutes",
      rruleString: "FREQ=MINUTELY;INTERVAL=5",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 15 minutes", category: "Minutes",
      rruleString: "FREQ=MINUTELY;INTERVAL=15",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 20 minutes", category: "Minutes",
      rruleString: "FREQ=MINUTELY;INTERVAL=20",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 30 minutes", category: "Minutes",
      rruleString: "FREQ=MINUTELY;INTERVAL=30",
      icon: "clock"
    ),

    // Hourly
    ScheduleTemplate(
      name: "Every Hour", category: "Hourly",
      rruleString: "FREQ=HOURLY",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 2 Hours", category: "Hourly",
      rruleString: "FREQ=HOURLY;INTERVAL=2",
      icon: "clock"
    ),
    ScheduleTemplate(
      name: "Every 4 Hours", category: "Hourly",
      rruleString: "FREQ=HOURLY;INTERVAL=4",
      icon: "clock"
    ),

    // Daily
    ScheduleTemplate(
      name: "Daily", category: "Daily",
      rruleString: "FREQ=DAILY",
      icon: "sun.max"
    ),
    ScheduleTemplate(
      name: "Weekdays", category: "Daily",
      rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Weekends", category: "Daily",
      rruleString: "FREQ=WEEKLY;BYDAY=SA,SU",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Daily at 9am", category: "Daily",
      rruleString: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      icon: "sun.max"
    ),

    // Weekly
    ScheduleTemplate(
      name: "Weekly", category: "Weekly",
      rruleString: "FREQ=WEEKLY",
      icon: "repeat"
    ),
    ScheduleTemplate(
      name: "Every Monday at 9 AM", category: "Weekly",
      rruleString: "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0",
      icon: "repeat"
    ),
    ScheduleTemplate(
      name: "Every Friday", category: "Weekly",
      rruleString: "FREQ=WEEKLY;BYDAY=FR",
      icon: "repeat"
    ),

    // Monthly
    ScheduleTemplate(
      name: "Monthly", category: "Monthly",
      rruleString: "FREQ=MONTHLY",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "First of Month", category: "Monthly",
      rruleString: "FREQ=MONTHLY;BYMONTHDAY=1",
      icon: "calendar"
    ),
    ScheduleTemplate(
      name: "Last of Month", category: "Monthly",
      rruleString: "FREQ=MONTHLY;BYMONTHDAY=-1",
      icon: "calendar"
    ),

    // One-time templates
    ScheduleTemplate(
      name: "Tomorrow at 9 AM", category: "Quick",
      rruleString: "",
      icon: "calendar"
    ),
  ]

  static var groupedTemplates: [String: [ScheduleTemplate]] {
    Dictionary(grouping: all, by: { $0.category })
  }

  static var quickTemplates: [ScheduleTemplate] {
    [
      all.first(where: { $0.name == "Every 20 minutes" }) ?? all[0],
      all.first(where: { $0.name == "9am Tomorrow" }) ?? all[1],
    ]
  }

  // Categorized templates for MORE expansion
  static let dailyTemplates: [ScheduleTemplate] = [
    ScheduleTemplate(name: "Walk the pets", category: "Daily", rruleString: "FREQ=DAILY;BYHOUR=19;BYMINUTE=0", icon: "pawprint.fill"),
    ScheduleTemplate(name: "Pushups 3x/day", category: "Daily", rruleString: "FREQ=DAILY;BYHOUR=7,12,19;BYMINUTE=0", icon: "figure.strengthtraining.traditional"),
    ScheduleTemplate(name: "Pick up kids", category: "Daily", rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=16;BYMINUTE=0", icon: "figure.2.and.child.holdinghands"),
  ]

  static let weeklyTemplates: [ScheduleTemplate] = [
    ScheduleTemplate(name: "Check mailbox", category: "Weekly", rruleString: "FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=0", icon: "envelope.fill"),
    ScheduleTemplate(name: "Take out trash", category: "Weekly", rruleString: "FREQ=WEEKLY;BYDAY=TH;BYHOUR=20;BYMINUTE=0", icon: "trash.fill"),
    ScheduleTemplate(name: "Security training", category: "Weekly", rruleString: "FREQ=WEEKLY;BYDAY=TU,TH;BYHOUR=14;BYMINUTE=0", icon: "shield.fill"),
    ScheduleTemplate(name: "Groceries", category: "Weekly", rruleString: "FREQ=WEEKLY;BYDAY=SA;BYHOUR=14;BYMINUTE=0", icon: "cart.fill"),
    ScheduleTemplate(name: "Bathroom cleanup", category: "Weekly", rruleString: "FREQ=WEEKLY;BYDAY=WE,SA;BYHOUR=15;BYMINUTE=0", icon: "sparkles"),
  ]

  static let monthlyYearlyTemplates: [ScheduleTemplate] = [
    ScheduleTemplate(name: "Rent reminder", category: "Monthly", rruleString: "FREQ=MONTHLY;BYDAY=-1MO;BYHOUR=9;BYMINUTE=0", icon: "dollarsign.circle.fill"),
    ScheduleTemplate(name: "Birthday", category: "Yearly", rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0", icon: "birthday.cake.fill"),
    ScheduleTemplate(name: "Anniversary", category: "Yearly", rruleString: "FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=3;BYHOUR=9;BYMINUTE=0", icon: "heart.fill"),
    ScheduleTemplate(name: "Declutter clothes", category: "Yearly", rruleString: "FREQ=YEARLY;BYMONTH=7;BYMONTHDAY=1;BYHOUR=10;BYMINUTE=0", icon: "tshirt.fill"),
  ]
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
  @State private var atTimes: [Date] = []

  // UI state
  @State private var selectedTemplate: ScheduleTemplate?
  @State private var selectedRRuleExample: RRuleExample?
  @State private var showMoreTemplates: Bool = false
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
      self._customRRule = State(initialValue: schedule.rrule)
      self._startDate = State(initialValue: schedule.dtstart)
      self._notes = State(initialValue: schedule.notes)
      self._enabled = State(initialValue: schedule.enabled)
      self._selectedPriority = State(initialValue: schedule.priority)
      self._selectedTemplate = State(initialValue: nil)

      // UI fields will be populated by syncRRuleStringToUI() in onAppear
    } else {
      let firstTemplate = ScheduleTemplates.quickTemplates.first
      self._selectedTemplate = State(initialValue: firstTemplate)
      self._customRRule = State(initialValue: firstTemplate?.rruleString ?? "FREQ=DAILY")

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
      .onAppear {
        // Populate UI fields from RRule when editing existing schedule
        if schedule != nil {
          syncRRuleStringToUI()
        }
      }
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

      // Quick templates row
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

        // MORE button
        Button(action: {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showMoreTemplates.toggle()
          }
        }) {
          Text(showMoreTemplates ? "LESS" : "MORE")
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.accentColor)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)

        Spacer()
      }

      // Expanded templates
      if showMoreTemplates {
        VStack(alignment: .leading, spacing: 16) {
          // Daily routines
          VStack(alignment: .leading, spacing: 8) {
            Text("Daily Routines")
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundColor(.secondary)
              .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
              ForEach(ScheduleTemplates.dailyTemplates, id: \.name) { template in
                QuickTemplateButton(
                  template: template,
                  isSelected: selectedTemplate?.name == template.name,
                  action: {
                    selectTemplate(template)
                  }
                )
              }
            }
          }

          // Weekly routines
          VStack(alignment: .leading, spacing: 8) {
            Text("Weekly Routines")
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundColor(.secondary)
              .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
              ForEach(ScheduleTemplates.weeklyTemplates, id: \.name) { template in
                QuickTemplateButton(
                  template: template,
                  isSelected: selectedTemplate?.name == template.name,
                  action: {
                    selectTemplate(template)
                  }
                )
              }
            }
          }

          // Monthly/Yearly routines
          VStack(alignment: .leading, spacing: 8) {
            Text("Monthly/Yearly")
              .font(.caption)
              .fontWeight(.semibold)
              .foregroundColor(.secondary)
              .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
              ForEach(ScheduleTemplates.monthlyYearlyTemplates, id: \.name) { template in
                QuickTemplateButton(
                  template: template,
                  isSelected: selectedTemplate?.name == template.name,
                  action: {
                    selectTemplate(template)
                  }
                )
              }
            }
          }
        }
        .padding(.top, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
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
            Text(recurrenceMode == .ui ? "RRule Mode" : "UI Mode")
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
        rruleModeRecurrenceSection
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

      // Note for complex patterns
      Text("💡 For complex patterns (e.g., every 10 min during work hours), use RRule Mode")
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.top, 8)
    }
    .onChange(of: selectedFrequency) { _, _ in syncUIToRRuleString() }
    .onChange(of: intervalValue) { _, _ in syncUIToRRuleString() }
    .onChange(of: endDate) { _, _ in syncUIToRRuleString() }
    .onChange(of: selectedWeekdays) { _, _ in syncUIToRRuleString() }
    .onChange(of: selectedMonthDays) { _, _ in syncUIToRRuleString() }
    .onChange(of: selectedMonths) { _, _ in syncUIToRRuleString() }
    .onChange(of: atTimes) { _, _ in syncUIToRRuleString() }
  }

  // MARK: - Frequency-Specific Controls
  private var weeklyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("On days")
        .font(.subheadline)
        .fontWeight(.medium)

      WeekdaySelector(selectedDays: $selectedWeekdays)

      Text("At times")
        .font(.subheadline)
        .fontWeight(.medium)

      // Show all times
      ForEach(Array(atTimes.enumerated()), id: \.offset) { index, time in
        HStack {
          DatePicker(
            "",
            selection: Binding(
              get: { time },
              set: { atTimes[index] = $0 }
            ),
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()

          Button(action: {
            atTimes.remove(at: index)
          }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.red)
          }
          .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
      }

      Button("Add time") {
        atTimes.append(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
      }
      .buttonStyle(.plain)
      .foregroundColor(.accentColor)
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

      Text("At times")
        .font(.subheadline)
        .fontWeight(.medium)

      // Show all times
      ForEach(Array(atTimes.enumerated()), id: \.offset) { index, time in
        HStack {
          DatePicker(
            "",
            selection: Binding(
              get: { time },
              set: { atTimes[index] = $0 }
            ),
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()

          Button(action: {
            atTimes.remove(at: index)
          }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.red)
          }
          .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
      }

      Button("Add time") {
        atTimes.append(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
      }
      .buttonStyle(.plain)
      .foregroundColor(.accentColor)
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

      Text("At times")
        .font(.subheadline)
        .fontWeight(.medium)

      // Show all times
      ForEach(Array(atTimes.enumerated()), id: \.offset) { index, time in
        HStack {
          DatePicker(
            "",
            selection: Binding(
              get: { time },
              set: { atTimes[index] = $0 }
            ),
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()

          Button(action: {
            atTimes.remove(at: index)
          }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.red)
          }
          .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
      }

      Button("Add time") {
        atTimes.append(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
      }
      .buttonStyle(.plain)
      .foregroundColor(.accentColor)
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
      Text("At times")
        .font(.subheadline)
        .fontWeight(.medium)

      // Show all times
      ForEach(Array(atTimes.enumerated()), id: \.offset) { index, time in
        HStack {
          DatePicker(
            "",
            selection: Binding(
              get: { time },
              set: { atTimes[index] = $0 }
            ),
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()

          Spacer()

          Button(action: {
            atTimes.remove(at: index)
          }) {
            Image(systemName: "xmark.circle.fill")
              .foregroundColor(.red)
          }
          .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
      }

      Button(action: {
        atTimes.append(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date())
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
    .padding(.leading, 4)
    .overlay(
      Rectangle()
        .fill(Color.accentColor)
        .frame(width: 3)
        .cornerRadius(1.5),
      alignment: .leading
    )
  }

  // MARK: - RRule Mode Recurrence
  private var rruleModeRecurrenceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("RFC 5545 RRule Format")
        .font(.caption)
        .foregroundColor(.secondary)

      // Example dropdown
      VStack(alignment: .leading, spacing: 6) {
        Text("Quick Examples:")
          .font(.subheadline)
          .fontWeight(.medium)

        Picker("", selection: $selectedRRuleExample) {
          Text("Custom").tag(nil as RRuleExample?)
          ForEach(RRuleExample.examples) { example in
            Text(example.name).tag(example as RRuleExample?)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: selectedRRuleExample) { _, newExample in
          if let example = newExample {
            customRRule = example.rruleString
          }
        }

        if let example = selectedRRuleExample {
          Text(example.description)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 4)
        }
      }
      .padding(10)
      .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
      .cornerRadius(8)

      TextEditor(text: $customRRule)
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .frame(minHeight: 200, maxHeight: 300)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 2)
        )
        .onChange(of: customRRule) { _, _ in
          syncRRuleStringToUI()
          // Reset example selection if user manually edits
          if selectedRRuleExample != nil && customRRule != selectedRRuleExample?.rruleString {
            selectedRRuleExample = nil
          }
        }

      // Help link
      HStack(spacing: 4) {
        Text("Need help?")
          .font(.caption)
          .foregroundColor(.secondary)
        Link("Visit RRule Generator", destination: URL(string: "https://rrule-wiz.lovable.app/")!)
          .font(.caption)
      }
      .padding(.top, 4)
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
      customRRule = template.rruleString

      // Always update the schedule name with the template name
      scheduleName = template.name

      // Check if this is a one-time event (blank RRule or COUNT=1)
      let isBlankRRule = template.rruleString.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty

      if isBlankRRule {
        isOneTimeEvent = true
        syncTimeFromTemplate(rrule: nil, templateName: template.name)
      } else if let rrule = try? RRule.fromRRuleString(template.rruleString) {
        isOneTimeEvent = (rrule.count == 1)

        // Sync time from template for one-time events
        if isOneTimeEvent {
          syncTimeFromTemplate(rrule: rrule, templateName: template.name)
        } else {
          // If switching from one-time to recurring, reset time to 5 mins from now
          if wasOneTimeEvent && isCreating {
            startDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
          }
          syncRRuleStringToUI()
        }
      }
    }
  }

  private func syncTimeFromTemplate(rrule: RRule?, templateName: String) {
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
      targetDate =
        calendar.date(byAdding: .day, value: daysUntilMonday == 0 ? 7 : daysUntilMonday, to: today)
        ?? Date()
    } else if templateName.contains("Next Sunday") {
      // Set to next Sunday
      let today = Date()
      let weekday = calendar.component(.weekday, from: today)
      let daysUntilSunday = (1 - weekday + 7) % 7
      targetDate =
        calendar.date(byAdding: .day, value: daysUntilSunday == 0 ? 7 : daysUntilSunday, to: today)
        ?? Date()
    } else {
      // Today at specific time
      targetDate = Date()
    }

    // Apply time from RRule if specified
    if let rrule = rrule, !rrule.byhour.isEmpty, let hour = rrule.byhour.first {
      let minute = rrule.byminute.first ?? 0
      if let dateWithTime = calendar.date(
        bySettingHour: hour, minute: minute, second: 0, of: targetDate)
      {
        startDate = dateWithTime
        return
      }
    }

    // Parse time from template name if it contains a specific time
    if let timeMatch = extractTimeFromTemplateName(templateName) {
      if let dateWithTime = calendar.date(
        bySettingHour: timeMatch.hour, minute: timeMatch.minute, second: 0, of: targetDate)
      {
        startDate = dateWithTime
        return
      }
    }

    // Default: 5 minutes from now
    startDate = calendar.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
  }

  private func extractTimeFromTemplateName(_ name: String) -> (hour: Int, minute: Int)? {
    // Extract time like "6pm", "9am", "2pm" from template name
    let lowercased = name.lowercased()

    // Pattern: "6pm", "9am", "2pm", etc.
    if let range = lowercased.range(of: #"\d{1,2}(am|pm)"#, options: .regularExpression) {
      let timeStr = String(lowercased[range])
      let isPM = timeStr.contains("pm")
      let hourStr = timeStr.replacingOccurrences(of: "am", with: "").replacingOccurrences(
        of: "pm", with: "")

      if var hour = Int(hourStr) {
        if isPM && hour != 12 {
          hour += 12
        } else if !isPM && hour == 12 {
          hour = 0
        }
        return (hour: hour, minute: 0)
      }
    }

    return nil
  }

  private func toggleRecurrenceMode() {
    if recurrenceMode == .ui {
      syncUIToRRuleString()
      recurrenceMode = .rrule
    } else {
      syncRRuleStringToUI()
      recurrenceMode = .ui
    }
  }

  private func syncUIToRRuleString() {
    let calendar = Calendar.current
    var byhour: [Int] = []
    var byminute: [Int] = []

    // Extract all times from atTimes array
    if !atTimes.isEmpty {
      // Extract hours and minutes from all times
      for time in atTimes {
        let hour = calendar.component(.hour, from: time)
        let minute = calendar.component(.minute, from: time)

        if !byhour.contains(hour) {
          byhour.append(hour)
        }
        if !byminute.contains(minute) {
          byminute.append(minute)
        }
      }

      // Sort for consistent output
      byhour.sort()
      byminute.sort()
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
    customRRule = rrule.toRRuleString()
  }

  private func syncRRuleStringToUI() {
    let trimmedRRule = customRRule.trimmingCharacters(in: .whitespacesAndNewlines)

    // If blank, it's a one-time event
    if trimmedRRule.isEmpty {
      isOneTimeEvent = true
      return
    }

    if let rrule = try? RRule.fromRRuleString(trimmedRRule) {
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

      // Parse times - support multiple BYHOUR values
      atTimes = []
      if !rrule.byhour.isEmpty {
        for hour in rrule.byhour {
          // If BYMINUTE is specified, create a time for each hour/minute combination
          if !rrule.byminute.isEmpty {
            for minute in rrule.byminute {
              if let time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
                atTimes.append(time)
              }
            }
          } else {
            // No BYMINUTE specified, use minute 0
            if let time = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) {
              atTimes.append(time)
            }
          }
        }
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

      // Validate RRule (allow empty for one-time events)
      let trimmedRRule = customRRule.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedRRule.isEmpty {
        // Validate RRule format if provided
        do {
          _ = try RRule.fromRRuleString(trimmedRRule)
        } catch {
          validationError = "Invalid RRule format: \(error.localizedDescription)"
          return
        }
      }
      // If empty, it's a one-time event (just uses dtstart)

      validationError = nil

      if isCreating {
        await scheduleViewModel.createSchedule(
          routineId: routineId,
          name: trimmedName,
          rrule: customRRule,
          dtstart: startDate,
          notes: trimmedNotes,
          enabled: enabled,
          priority: selectedPriority
        )
      } else if let schedule = schedule {
        var updatedSchedule = schedule
        updatedSchedule.name = trimmedName
        updatedSchedule.rrule = customRRule
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
    ("S", "SA"),
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
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
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
