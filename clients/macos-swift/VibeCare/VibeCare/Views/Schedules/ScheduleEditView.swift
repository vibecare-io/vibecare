@preconcurrency import OpenTelemetryApi
import SwiftUI

// Template definitions
struct ScheduleTemplate: Identifiable, Hashable {
  let id = UUID()
  let name: String
  let category: String
  let rruleJSON: String

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
  // Cache for expensive operations
  // Remove caching for now to avoid concurrency complexity
  // TODO: Implement proper concurrent caching if needed for performance

  static let all: [ScheduleTemplate] = [
    // One-Shot Events (use count=1 for one-time execution)
    ScheduleTemplate(
      name: "6pm Today", category: "One-Time",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "9am Tomorrow", category: "One-Time",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "2pm Next Sunday", category: "One-Time",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Next Monday", category: "One-Time",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),

    // Frequent (Minutes)
    ScheduleTemplate(
      name: "Every 5 minutes", category: "Minutes",
      rruleJSON:
        #"{"freq":"MINUTELY","interval":5,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every 15 minutes", category: "Minutes",
      rruleJSON:
        #"{"freq":"MINUTELY","interval":15,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every 30 minutes", category: "Minutes",
      rruleJSON:
        #"{"freq":"MINUTELY","interval":30,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),

    // Hourly
    ScheduleTemplate(
      name: "Every Hour", category: "Hourly",
      rruleJSON:
        #"{"freq":"HOURLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every 2 Hours", category: "Hourly",
      rruleJSON:
        #"{"freq":"HOURLY","interval":2,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every 4 Hours", category: "Hourly",
      rruleJSON:
        #"{"freq":"HOURLY","interval":4,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),

    // Daily
    ScheduleTemplate(
      name: "Daily", category: "Daily",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Weekdays", category: "Daily",
      rruleJSON:
        #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["MO","TU","WE","TH","FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Weekends", category: "Daily",
      rruleJSON:
        #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["SA","SU"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Daily at 9am", category: "Daily",
      rruleJSON:
        #"{"freq":"DAILY","interval":1,"byhour":[9],"byminute":[0],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),

    // Weekly
    ScheduleTemplate(
      name: "Weekly", category: "Weekly",
      rruleJSON:
        #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every Monday", category: "Weekly",
      rruleJSON:
        #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["MO"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Every Friday", category: "Weekly",
      rruleJSON:
        #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),

    // Monthly
    ScheduleTemplate(
      name: "Monthly", category: "Monthly",
      rruleJSON:
        #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "First of Month", category: "Monthly",
      rruleJSON:
        #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
    ScheduleTemplate(
      name: "Last of Month", category: "Monthly",
      rruleJSON:
        #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[-1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    ),
  ]

  static var groupedTemplates: [String: [ScheduleTemplate]] {
    Dictionary(grouping: all, by: { $0.category })
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

  @State private var scheduleName: String = ""
  @State private var selectedTemplate: ScheduleTemplate?
  @State private var customRRule: String = ""
  @State private var startDate: Date = {
    // Set default to next hour for new schedules
    let calendar = Calendar.current
    let now = Date()
    let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
    return nextHour
  }()
  @State private var notes: String = ""
  @State private var enabled: Bool = true
  @State private var validationError: String?
  @State private var isEditingJSON: Bool = false
  @State private var showAdvanced: Bool = false

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

    // Create init span as child of parent if available
    let initSpan: Span
    if let parentSpan = parentSpan {
      initSpan = OTELManager.shared.traceChildViewInit("ScheduleEditView", parent: parentSpan)
    } else {
      initSpan = OTELManager.shared.traceViewInit("ScheduleEditView")
    }

    // Enhanced metadata for investigation
    initSpan.setAttribute(key: "routine.id", value: AttributeValue.string(routineId))
    initSpan.setAttribute(key: "is_creating", value: AttributeValue.bool(isCreating))
    initSpan.setAttribute(key: "has_schedule", value: AttributeValue.bool(schedule != nil))
    initSpan.setAttribute(key: "has_parent_span", value: AttributeValue.bool(parentSpan != nil))

    // Sequence and timing tracking
    initSpan.setAttribute(
      key: "init_sequence_number", value: AttributeValue.int(initSequenceNumber))
    initSpan.setAttribute(
      key: "init_timestamp",
      value: AttributeValue.string(ISO8601DateFormatter().string(from: initStartTime)))
    initSpan.setAttribute(key: "thread_is_main", value: AttributeValue.bool(Thread.isMainThread))
    initSpan.setAttribute(
      key: "thread_name", value: AttributeValue.string(Thread.current.name ?? "unnamed"))

    // State change tracking
    if let schedule = schedule {
      initSpan.setAttribute(key: "schedule.id", value: AttributeValue.string(schedule.id))
      initSpan.setAttribute(key: "schedule.name", value: AttributeValue.string(schedule.name))
      initSpan.setAttribute(key: "schedule.enabled", value: AttributeValue.bool(schedule.enabled))
      initSpan.setAttribute(
        key: "schedule.object_hash",
        value: AttributeValue.string(String(ObjectIdentifier(schedule as AnyObject).hashValue)))
    }

    // ViewModel tracking
    initSpan.setAttribute(
      key: "view_model.object_hash",
      value: AttributeValue.string(String(ObjectIdentifier(scheduleViewModel).hashValue)))

    // Detailed object tracking
    if let schedule = schedule {
      initSpan.setAttribute(
        key: "schedule.detailed_hash", value: AttributeValue.string(String(schedule.hashValue)))
      initSpan.setAttribute(
        key: "schedule.dtstart",
        value: AttributeValue.string(ISO8601DateFormatter().string(from: schedule.dtstart)))
      initSpan.setAttribute(
        key: "schedule.notes_length", value: AttributeValue.int(schedule.notes.count))
      initSpan.setAttribute(
        key: "schedule.recurrence_json_hash",
        value: AttributeValue.string(String(schedule.recurrenceJSON.hashValue)))
    }

    // Parent span tracking
    if let parentSpan = parentSpan {
      initSpan.setAttribute(
        key: "parent_span.trace_id",
        value: AttributeValue.string(parentSpan.context.traceId.hexString))
      initSpan.setAttribute(
        key: "parent_span.span_id",
        value: AttributeValue.string(parentSpan.context.spanId.hexString))
    }

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

    // Trace different initialization paths
    if let schedule = schedule {
      let editInitSpan = OTELManager.shared.startSpan("schedule_edit_view.init_existing")
      editInitSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      editInitSpan.setAttribute(key: "schedule.id", value: AttributeValue.string(schedule.id))
      editInitSpan.setAttribute(key: "schedule.name", value: AttributeValue.string(schedule.name))
      editInitSpan.setAttribute(
        key: "schedule.recurrence_json_length",
        value: AttributeValue.int(schedule.recurrenceJSON.count))
      editInitSpan.setAttribute(
        key: "schedule.dtstart",
        value: AttributeValue.string(ISO8601DateFormatter().string(from: schedule.dtstart)))
      editInitSpan.setAttribute(
        key: "schedule.notes_length", value: AttributeValue.int(schedule.notes.count))
      editInitSpan.setAttribute(
        key: "schedule.routine_id", value: AttributeValue.string(schedule.routineId))

      // Trace state initialization steps
      let stateInitSpan = OTELManager.shared.startSpan("schedule_edit_view.state_initialization")
      let stateInitStartTime = Date()

      self._scheduleName = State(initialValue: schedule.name)
      self._customRRule = State(initialValue: schedule.recurrenceJSON)
      self._startDate = State(initialValue: schedule.dtstart)
      self._notes = State(initialValue: schedule.notes)
      self._enabled = State(initialValue: schedule.enabled)
      self._selectedTemplate = State(initialValue: nil)

      let stateInitDuration = Date().timeIntervalSince(stateInitStartTime)
      stateInitSpan.setAttribute(
        key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      stateInitSpan.setAttribute(key: "name_length", value: AttributeValue.int(schedule.name.count))
      stateInitSpan.setAttribute(
        key: "notes_length", value: AttributeValue.int(schedule.notes.count))
      stateInitSpan.setAttribute(
        key: "rrule_json_length", value: AttributeValue.int(schedule.recurrenceJSON.count))
      stateInitSpan.setAttribute(
        key: "state_init_duration_ms", value: AttributeValue.double(stateInitDuration * 1000))
      stateInitSpan.status = .ok
      stateInitSpan.end()

      editInitSpan.status = .ok
      editInitSpan.end()
    } else {
      let newInitSpan = OTELManager.shared.startSpan("schedule_edit_view.init_new")
      newInitSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))

      // Trace template loading with timing
      let templateSpan = OTELManager.shared.startSpan("schedule_templates.all_access")
      let templateLoadStartTime = Date()

      let allTemplates = ScheduleTemplates.all
      let templateLoadDuration = Date().timeIntervalSince(templateLoadStartTime)

      templateSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      templateSpan.setAttribute(
        key: "templates.count", value: AttributeValue.int(allTemplates.count))
      templateSpan.setAttribute(
        key: "load_duration_ms", value: AttributeValue.double(templateLoadDuration * 1000))

      let firstTemplate = allTemplates.first
      templateSpan.setAttribute(
        key: "first_template_name", value: AttributeValue.string(firstTemplate?.name ?? "none"))
      templateSpan.status = .ok
      templateSpan.end()

      // Trace state setup for new schedule
      let newStateSpan = OTELManager.shared.startSpan("schedule_edit_view.new_state_setup")
      let newStateStartTime = Date()

      self._selectedTemplate = State(initialValue: firstTemplate)
      self._customRRule = State(initialValue: firstTemplate?.rruleJSON ?? "{}")

      // Set better default name for new schedules
      if let firstTemplate = firstTemplate {
        self._scheduleName = State(initialValue: firstTemplate.name)
      }

      let newStateDuration = Date().timeIntervalSince(newStateStartTime)
      newStateSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      newStateSpan.setAttribute(
        key: "default_rrule_length",
        value: AttributeValue.int((firstTemplate?.rruleJSON ?? "{}").count))
      newStateSpan.setAttribute(
        key: "first_template_name", value: AttributeValue.string(firstTemplate?.name ?? "none"))
      newStateSpan.setAttribute(
        key: "new_state_duration_ms", value: AttributeValue.double(newStateDuration * 1000))
      newStateSpan.status = .ok
      newStateSpan.end()

      newInitSpan.status = .ok
      newInitSpan.end()
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Schedule Details
          scheduleDetailsCard

          // Timing
          timingCard
            
          // Advanced Configuration
          advancedCard
            
          // Quick Template Selection
          quickTemplateSection
          
                   
          // Bottom spacing
          Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
      }
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
          Button(isCreating ? "Create" : "Save") {
            saveSchedule()
          }
          .disabled(scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .withTracing(viewName: "ScheduleEditView", parentSpan: parentSpan)
    }
  }

  // MARK: - Quick Template Selection

  private var quickTemplateSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Quick Templates")
        .font(.headline)
        .fontWeight(.semibold)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
        ForEach(quickTemplates, id: \.name) { template in
          Button(action: {
            selectTemplate(template)
          }) {
            VStack(spacing: 4) {
              Text(template.name)
                .font(.caption)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
              Text(template.category)
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(selectedTemplate?.name == template.name ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(selectedTemplate?.name == template.name ? Color.accentColor : Color.clear, lineWidth: 2)
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  // MARK: - Schedule Details Card

  private var scheduleDetailsCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Schedule Details")
        .font(.headline)
        .fontWeight(.semibold)

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Name")
            .font(.subheadline)
            .fontWeight(.medium)

          TextField("Enter schedule name", text: $scheduleName)
            .textFieldStyle(.roundedBorder)

          if let error = validationError {
            Text(error)
              .font(.caption)
              .foregroundColor(.red)
          }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Notes")
            .font(.subheadline)
            .fontWeight(.medium)

          TextField("Optional notes", text: $notes, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        }
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  // MARK: - Advanced Configuration Card

  private var advancedCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          showAdvanced.toggle()
        }
      }) {
        HStack {
          Text("Advanced Configuration")
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)

          Spacer()

          Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
      }
      .buttonStyle(.plain)

      if showAdvanced {
        VStack(alignment: .leading, spacing: 16) {
          // Template Picker
          VStack(alignment: .leading, spacing: 8) {
            Text("All Templates")
              .font(.subheadline)
              .fontWeight(.medium)

            Picker("Template", selection: $selectedTemplate) {
              Text("Custom").tag(nil as ScheduleTemplate?)
              ForEach(ScheduleTemplates.groupedTemplates.keys.sorted(), id: \.self) { category in
                Section(category) {
                  ForEach(ScheduleTemplates.groupedTemplates[category] ?? []) { template in
                    Text(template.name).tag(template as ScheduleTemplate?)
                  }
                }
              }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedTemplate) { _, newTemplate in
              TraceableAction(actionName: "template_selection", component: "advanced_picker").execute {
                if let template = newTemplate {
                  customRRule = template.rruleJSON
                  if scheduleName.isEmpty {
                    scheduleName = template.name
                  }
                }
              }
            }
          }

          // JSON Editor
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("RRule JSON")
                .font(.subheadline)
                .fontWeight(.medium)

              Spacer()

              Button("Reset") {
                customRRule = ScheduleTemplates.all.first?.rruleJSON ?? "{}"
                selectedTemplate = nil
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }

            TextEditor(text: $customRRule)
              .font(.system(.caption, design: .monospaced))
              .padding(12)
              .background(Color(NSColor.textBackgroundColor))
              .overlay(
                RoundedRectangle(cornerRadius: 8)
                  .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
              )
              .frame(minHeight: 80, maxHeight: 120)
              .onChange(of: customRRule) { _, _ in
                if isEditingJSON {
                  selectedTemplate = nil
                }
              }
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  // MARK: - Timing Card

  private var timingCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Timing")
        .font(.headline)
        .fontWeight(.semibold)

      VStack(alignment: .leading, spacing: 6) {
        Text("Start Date & Time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
          .datePickerStyle(.compact)
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  // MARK: - Computed Properties

  private var currentRRuleJSON: String {
    return customRRule
  }

  private var quickTemplates: [ScheduleTemplate] {
    [
      ScheduleTemplates.all.first(where: { $0.name == "6pm Today" }) ?? ScheduleTemplates.all[0],
      ScheduleTemplates.all.first(where: { $0.name == "Daily" }) ?? ScheduleTemplates.all[1],
      ScheduleTemplates.all.first(where: { $0.name == "Weekly" }) ?? ScheduleTemplates.all[2],
      ScheduleTemplates.all.first(where: { $0.name == "Weekdays" }) ?? ScheduleTemplates.all[3],
      ScheduleTemplates.all.first(where: { $0.name == "Every Hour" }) ?? ScheduleTemplates.all[4],
      ScheduleTemplates.all.first(where: { $0.name == "Monthly" }) ?? ScheduleTemplates.all[5]
    ]
  }

  // MARK: - Helper Methods

  private func selectTemplate(_ template: ScheduleTemplate) {
    TraceableAction(actionName: "quick_template_select", component: "template_grid").execute {
      selectedTemplate = template
      customRRule = template.rruleJSON
      if scheduleName.isEmpty || scheduleName == selectedTemplate?.name {
        scheduleName = template.name
      }
    }
  }

  // MARK: - Actions

  private func saveSchedule() {
    Task { @MainActor in
      // Simple validation
      let trimmedName = scheduleName.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !trimmedName.isEmpty else {
        return
      }

      guard !customRRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        validationError = "RRule JSON cannot be empty"
        return
      }

      // Clear any previous validation errors
      validationError = nil

      // Perform the save operation
      if isCreating {
        await scheduleViewModel.createSchedule(
          routineId: routineId,
          name: trimmedName,
          recurrenceJSON: currentRRuleJSON,
          dtstart: startDate,
          notes: trimmedNotes,
          enabled: enabled
        )
      } else if let schedule = schedule {
        var updatedSchedule = schedule
        updatedSchedule.name = trimmedName
        updatedSchedule.recurrenceJSON = currentRRuleJSON
        updatedSchedule.dtstart = startDate
        updatedSchedule.notes = trimmedNotes
        updatedSchedule.enabled = enabled

        await scheduleViewModel.updateSchedule(updatedSchedule)
      }

      // End parent span if we have one before dismissing
      if let parentSpan = parentSpan {
        parentSpan.status = .ok
        parentSpan.end()
      }

      onDismiss()
    }
  }

  enum ValidationError: Error {
    case emptyName
    case emptyRRule
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
  .frame(width: 600, height: 700)
}
