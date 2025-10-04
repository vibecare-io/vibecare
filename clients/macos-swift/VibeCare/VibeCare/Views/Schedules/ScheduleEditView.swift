import SwiftUI
import OpenTelemetryApi

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
    )
    // ScheduleTemplate(
    //   name: "9am Tomorrow", category: "One-Time",
    //   rruleJSON:
    //     #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "2pm Next Sunday", category: "One-Time",
    //   rruleJSON:
    //     #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Next Monday", category: "One-Time",
    //   rruleJSON:
    //     #"{"freq":"DAILY","interval":1,"count":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),

    // // Frequent (Minutes)
    // ScheduleTemplate(
    //   name: "Every 5 minutes", category: "Minutes",
    //   rruleJSON:
    //     #"{"freq":"MINUTELY","interval":5,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every 15 minutes", category: "Minutes",
    //   rruleJSON:
    //     #"{"freq":"MINUTELY","interval":15,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every 30 minutes", category: "Minutes",
    //   rruleJSON:
    //     #"{"freq":"MINUTELY","interval":30,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),

    // // Hourly
    // ScheduleTemplate(
    //   name: "Every Hour", category: "Hourly",
    //   rruleJSON:
    //     #"{"freq":"HOURLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every 2 Hours", category: "Hourly",
    //   rruleJSON:
    //     #"{"freq":"HOURLY","interval":2,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every 4 Hours", category: "Hourly",
    //   rruleJSON:
    //     #"{"freq":"HOURLY","interval":4,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),

    // // Daily
    // ScheduleTemplate(
    //   name: "Daily", category: "Daily",
    //   rruleJSON:
    //     #"{"freq":"DAILY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Weekdays", category: "Daily",
    //   rruleJSON:
    //     #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["MO","TU","WE","TH","FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Weekends", category: "Daily",
    //   rruleJSON:
    //     #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["SA","SU"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Daily at 9am", category: "Daily",
    //   rruleJSON:
    //     #"{"freq":"DAILY","interval":1,"byhour":[9],"byminute":[0],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),

    // // Weekly
    // ScheduleTemplate(
    //   name: "Weekly", category: "Weekly",
    //   rruleJSON:
    //     #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every Monday", category: "Weekly",
    //   rruleJSON:
    //     #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["MO"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Every Friday", category: "Weekly",
    //   rruleJSON:
    //     #"{"freq":"WEEKLY","interval":1,"byhour":[],"byminute":[],"byday":["FR"],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),

    // // Monthly
    // ScheduleTemplate(
    //   name: "Monthly", category: "Monthly",
    //   rruleJSON:
    //     #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "First of Month", category: "Monthly",
    //   rruleJSON:
    //     #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
    // ScheduleTemplate(
    //   name: "Last of Month", category: "Monthly",
    //   rruleJSON:
    //     #"{"freq":"MONTHLY","interval":1,"byhour":[],"byminute":[],"byday":[],"bymonthday":[-1],"bymonth":[],"byweekno":[],"byyearday":[],"wkst":"MO"}"#
    // ),
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
  @State private var startDate: Date = Date()
  @State private var notes: String = ""
  @State private var enabled: Bool = true
  @State private var validationError: String?
  @State private var isEditingJSON: Bool = false

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
    initSpan.setAttribute(key: "init_sequence_number", value: AttributeValue.int(initSequenceNumber))
    initSpan.setAttribute(key: "init_timestamp", value: AttributeValue.string(ISO8601DateFormatter().string(from: initStartTime)))
    initSpan.setAttribute(key: "thread_is_main", value: AttributeValue.bool(Thread.isMainThread))
    initSpan.setAttribute(key: "thread_name", value: AttributeValue.string(Thread.current.name ?? "unnamed"))

    // State change tracking
    if let schedule = schedule {
      initSpan.setAttribute(key: "schedule.id", value: AttributeValue.string(schedule.id))
      initSpan.setAttribute(key: "schedule.name", value: AttributeValue.string(schedule.name))
      initSpan.setAttribute(key: "schedule.enabled", value: AttributeValue.bool(schedule.enabled))
      initSpan.setAttribute(key: "schedule.object_hash", value: AttributeValue.string(String(ObjectIdentifier(schedule as AnyObject).hashValue)))
    }

    // ViewModel tracking
    initSpan.setAttribute(key: "view_model.object_hash", value: AttributeValue.string(String(ObjectIdentifier(scheduleViewModel).hashValue)))

    // Detailed object tracking
    if let schedule = schedule {
      initSpan.setAttribute(key: "schedule.detailed_hash", value: AttributeValue.string(String(schedule.hashValue)))
      initSpan.setAttribute(key: "schedule.dtstart", value: AttributeValue.string(ISO8601DateFormatter().string(from: schedule.dtstart)))
      initSpan.setAttribute(key: "schedule.notes_length", value: AttributeValue.int(schedule.notes.count))
      initSpan.setAttribute(key: "schedule.recurrence_json_hash", value: AttributeValue.string(String(schedule.recurrenceJSON.hashValue)))
    }

    // Parent span tracking
    if let parentSpan = parentSpan {
      initSpan.setAttribute(key: "parent_span.trace_id", value: AttributeValue.string(parentSpan.context.traceId.hexString))
      initSpan.setAttribute(key: "parent_span.span_id", value: AttributeValue.string(parentSpan.context.spanId.hexString))
    }

    defer {
      let initEndTime = Date()
      let initDuration = initEndTime.timeIntervalSince(initStartTime)
      initSpan.setAttribute(key: "init_duration_ms", value: AttributeValue.double(initDuration * 1000))
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
      editInitSpan.setAttribute(key: "schedule.recurrence_json_length", value: AttributeValue.int(schedule.recurrenceJSON.count))
      editInitSpan.setAttribute(key: "schedule.dtstart", value: AttributeValue.string(ISO8601DateFormatter().string(from: schedule.dtstart)))
      editInitSpan.setAttribute(key: "schedule.notes_length", value: AttributeValue.int(schedule.notes.count))
      editInitSpan.setAttribute(key: "schedule.routine_id", value: AttributeValue.string(schedule.routineId))

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
      stateInitSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      stateInitSpan.setAttribute(key: "name_length", value: AttributeValue.int(schedule.name.count))
      stateInitSpan.setAttribute(key: "notes_length", value: AttributeValue.int(schedule.notes.count))
      stateInitSpan.setAttribute(key: "rrule_json_length", value: AttributeValue.int(schedule.recurrenceJSON.count))
      stateInitSpan.setAttribute(key: "state_init_duration_ms", value: AttributeValue.double(stateInitDuration * 1000))
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
      templateSpan.setAttribute(key: "templates.count", value: AttributeValue.int(allTemplates.count))
      templateSpan.setAttribute(key: "load_duration_ms", value: AttributeValue.double(templateLoadDuration * 1000))

      let firstTemplate = allTemplates.first
      templateSpan.setAttribute(key: "first_template_name", value: AttributeValue.string(firstTemplate?.name ?? "none"))
      templateSpan.status = .ok
      templateSpan.end()

      // Trace state setup for new schedule
      let newStateSpan = OTELManager.shared.startSpan("schedule_edit_view.new_state_setup")
      let newStateStartTime = Date()

      self._selectedTemplate = State(initialValue: firstTemplate)
      self._customRRule = State(initialValue: firstTemplate?.rruleJSON ?? "{}")

      let newStateDuration = Date().timeIntervalSince(newStateStartTime)
      newStateSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
      newStateSpan.setAttribute(key: "default_rrule_length", value: AttributeValue.int((firstTemplate?.rruleJSON ?? "{}").count))
      newStateSpan.setAttribute(key: "first_template_name", value: AttributeValue.string(firstTemplate?.name ?? "none"))
      newStateSpan.setAttribute(key: "new_state_duration_ms", value: AttributeValue.double(newStateDuration * 1000))
      newStateSpan.status = .ok
      newStateSpan.end()

      newInitSpan.status = .ok
      newInitSpan.end()
    }
  }

  var body: some View {
    let bodyStartTime = Date()
    let bodySpan = OTELManager.shared.traceViewBody("ScheduleEditView")
    bodySpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
    bodySpan.setAttribute(key: "is_creating", value: AttributeValue.bool(isCreating))
    bodySpan.setAttribute(key: "has_schedule", value: AttributeValue.bool(schedule != nil))
    bodySpan.setAttribute(key: "body_call_timestamp", value: AttributeValue.string(ISO8601DateFormatter().string(from: bodyStartTime)))
    bodySpan.setAttribute(key: "thread_is_main", value: AttributeValue.bool(Thread.isMainThread))
    defer {
      let bodyDuration = Date().timeIntervalSince(bodyStartTime)
      bodySpan.setAttribute(key: "body_duration_ms", value: AttributeValue.double(bodyDuration * 1000))
      bodySpan.status = .ok
      bodySpan.end()
    }

    // Trace UI construction time
    let uiConstructionSpan = OTELManager.shared.startSpan("schedule_edit_view.ui_construction")
    uiConstructionSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
    defer {
      uiConstructionSpan.status = .ok
      uiConstructionSpan.end()
    }

    return NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 32) {
          // Schedule Details
          scheduleDetailsSection

          // Recurrence Configuration
          recurrenceSection

          // Timing and Options
          timingSection

          // Bottom spacing
          Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
      }
      .navigationTitle(isCreating ? "Add Schedule" : "Edit Schedule")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onDismiss()
          }
        }

        ToolbarItem(placement: .principal) {
          Toggle("Enabled", isOn: $enabled)
            .toggleStyle(.switch)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button(isCreating ? "Create" : "Save") {
            saveSchedule()
          }
          .disabled(scheduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .onAppear {
        let appearSpan = OTELManager.shared.traceViewAppear("ScheduleEditView")
        appearSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
        appearSpan.setAttribute(key: "is_creating", value: AttributeValue.bool(isCreating))
        appearSpan.setAttribute(key: "has_schedule", value: AttributeValue.bool(schedule != nil))
        appearSpan.setAttribute(key: "appear_timestamp", value: AttributeValue.string(ISO8601DateFormatter().string(from: Date())))
        appearSpan.status = .ok
        appearSpan.end()
      }
      .onDisappear {
        let disappearSpan = OTELManager.shared.startSpan("view.disappear")
        disappearSpan.setAttribute(key: "view.name", value: AttributeValue.string("ScheduleEditView"))
        disappearSpan.setAttribute(key: "init_sequence", value: AttributeValue.int(initSequenceNumber))
        disappearSpan.setAttribute(key: "disappear_timestamp", value: AttributeValue.string(ISO8601DateFormatter().string(from: Date())))
        disappearSpan.status = .ok
        disappearSpan.end()
      }
    }
  }

  // MARK: - Schedule Details Section

  private var scheduleDetailsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Name")
          .font(.subheadline)
          .fontWeight(.medium)

        TextField("Schedule name", text: $scheduleName)
          .textFieldStyle(.roundedBorder)

        if let error = validationError {
          Text(error)
            .font(.caption)
            .foregroundColor(.red)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Notes")
          .font(.subheadline)
          .fontWeight(.medium)

        TextField("Optional notes", text: $notes, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(3...6)
      }
    }
  }

  // MARK: - Recurrence Section

  private var recurrenceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Recurrence")
        .font(.title2)
        .fontWeight(.semibold)

      // Template Picker with grouped options
      VStack(alignment: .leading, spacing: 12) {
        Text("Select Template")
          .font(.subheadline)
          .fontWeight(.medium)

        Picker("Template", selection: $selectedTemplate) {
          Text("None").tag(nil as ScheduleTemplate?)
          ForEach(ScheduleTemplates.all) { template in
            Text("\(template.category): \(template.name)").tag(template as ScheduleTemplate?)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedTemplate) { _, newTemplate in
          let span = OTELManager.shared.startSpan("template_selection_changed")
          defer { span.end() }

          if let template = newTemplate {
            span.setAttribute(key: "template.name", value: AttributeValue.string(template.name))
            span.setAttribute(key: "template.category", value: AttributeValue.string(template.category))
            span.setAttribute(key: "json.length", value: AttributeValue.int(template.rruleJSON.count))

            customRRule = template.rruleJSON
            if scheduleName.isEmpty {
              scheduleName = template.name
            }
          }
        }
      }

      // Editable JSON field
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("RRule JSON")
            .font(.subheadline)
            .fontWeight(.medium)

          Spacer()

          Button("Clear") {
            customRRule = "{}"
            selectedTemplate = nil
          }
          .buttonStyle(.bordered)
          .controlSize(.small)

          Text(isEditingJSON ? "Editing..." : "Click to edit")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        TextEditor(text: $customRRule)
          .font(.system(.body, design: .monospaced))
          .padding(16)
          .background(Color(NSColor.darkGray).opacity(0.1))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(
                isEditingJSON ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
          )
          .cornerRadius(12)
          .frame(minHeight: 120, maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .onTapGesture {
            isEditingJSON = true
          }
          .onChange(of: customRRule) { _, _ in
            // Clear template selection when JSON is manually edited
            if isEditingJSON {
              selectedTemplate = nil
            }
          }
          .onSubmit {
            isEditingJSON = false
          }
      }
    }
  }

  // MARK: - Timing Section

  private var timingSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Timing")
        .font(.title2)
        .fontWeight(.semibold)

      VStack(alignment: .leading, spacing: 8) {
        Text("Start Date & Time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
          .datePickerStyle(.compact)
      }
    }
  }



  // MARK: - Computed Properties

  private var currentRRuleJSON: String {
    return customRRule
  }


  // MARK: - Actions

  private func saveSchedule() {
    Task {
      // Create save span as child of parent if available
      let saveSpan: Span
      if let parentSpan = parentSpan {
        saveSpan = OTELManager.shared.createChildSpan(
          parent: parentSpan,
          operationName: "schedule_save_operation",
          attributes: [
            "is_creating": AttributeValue.bool(isCreating),
            "schedule.name": AttributeValue.string(scheduleName)
          ]
        )
      } else {
        saveSpan = OTELManager.shared.startSpan("schedule_save_operation")
        saveSpan.setAttribute(key: "is_creating", value: AttributeValue.bool(isCreating))
      }
      defer { saveSpan.end() }

      // Simple validation - just check if RRule JSON is not empty
      let trimmedName = scheduleName.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

      if trimmedName.isEmpty {
        saveSpan.status = .error(description: "Empty name")
        return // Button should be disabled, but double-check
      }

      if customRRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        saveSpan.status = .error(description: "Empty RRule JSON")
        validationError = "RRule JSON cannot be empty"
        return
      }

      if isCreating {
        let createSpan = OTELManager.shared.createChildSpan(
          parent: saveSpan,
          operationName: "schedule_create",
          attributes: [
            "routine.id": AttributeValue.string(routineId),
            "schedule.name": AttributeValue.string(trimmedName)
          ]
        )
        await scheduleViewModel.createSchedule(
          routineId: routineId,
          name: trimmedName,
          recurrenceJSON: currentRRuleJSON,
          dtstart: startDate,
          notes: trimmedNotes,
          enabled: enabled
        )
        createSpan.status = .ok
        createSpan.end()
      } else if let schedule = schedule {
        let updateSpan = OTELManager.shared.createChildSpan(
          parent: saveSpan,
          operationName: "schedule_update",
          attributes: [
            "schedule.id": AttributeValue.string(schedule.id),
            "schedule.name": AttributeValue.string(trimmedName)
          ]
        )

        var updatedSchedule = schedule
        updatedSchedule.name = trimmedName
        updatedSchedule.recurrenceJSON = currentRRuleJSON
        updatedSchedule.dtstart = startDate
        updatedSchedule.notes = trimmedNotes
        updatedSchedule.enabled = enabled

        await scheduleViewModel.updateSchedule(updatedSchedule)
        updateSpan.status = .ok
        updateSpan.end()
      }

      saveSpan.status = .ok

      // End parent span if we have one before dismissing
      if let parentSpan = parentSpan {
        parentSpan.status = .ok
        parentSpan.end()
      }

      onDismiss()
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
  .frame(width: 600, height: 700)
}
