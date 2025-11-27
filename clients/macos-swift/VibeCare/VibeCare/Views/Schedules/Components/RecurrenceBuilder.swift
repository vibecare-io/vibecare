import SwiftUI

/// Monthly recurrence mode: by day of month (e.g., "15th") or day of week (e.g., "first Monday")
enum MonthlyMode: String, CaseIterable {
  case dayOfMonth
  case dayOfWeek
}

/// Main recurrence builder component with progressive disclosure
/// Provides intuitive UI for building RRule recurrence patterns
struct RecurrenceBuilder: View {
  @Binding var rruleString: String
  @Binding var startDate: Date
  var onRRuleChange: ((String) -> Void)?

  // Optional: Excluded dates (for "More options" section)
  var excludedDates: Binding<[String]>?
  var onExdatesChange: (([String]) -> Void)?

  // MARK: - Internal State

  @State private var isRepeating: Bool = false
  @State private var frequency: RRule.Frequency = .daily
  @State private var interval: Int = 1
  @State private var selectedWeekdays: Set<String> = []
  @State private var selectedMonthDays: Set<Int> = []
  @State private var monthlyMode: MonthlyMode = .dayOfMonth
  @State private var ordinalPosition: OrdinalPosition = .first
  @State private var ordinalWeekday: String = "MO"
  @State private var selectedMonths: Set<Int> = []
  @State private var atTimes: [Date] = [Date()]
  @State private var useCount: Bool = false
  @State private var countValue: Int = 10
  @State private var useUntil: Bool = false
  @State private var untilDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
  @State private var showAdvanced: Bool = false
  @State private var showMoreOptions: Bool = false  // For Ends + Advanced section
  @State private var editingRRule: String = ""
  @State private var hasInitialized: Bool = false
  @State private var isExpanded: Bool = false  // Collapsed by default, showing summary only

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Date & Repeat toggle in horizontal layout
      dateAndRepeatSection

      // Animated recurrence options (when repeating)
      if isRepeating {
        recurrenceOptionsSection
          .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .move(edge: .top))
          ))
      }
    }
    .onAppear {
      if !hasInitialized {
        syncRRuleToUI()
        hasInitialized = true
      }
    }
    .onChange(of: rruleString) { _, newValue in
      if !showAdvanced {
        syncRRuleToUI()
      }
    }
  }

  // MARK: - Date & Repeat Section (Single Row Layout)

  private var dateAndRepeatSection: some View {
    HStack(spacing: 16) {
      // Start Date label + picker
      Text(isRepeating ? "Start Date" : "Date & Time")
        .font(.subheadline)
        .fontWeight(.medium)

      DatePicker(
        "",
        selection: $startDate,
        displayedComponents: isRepeating ? [.date] : [.date, .hourAndMinute]
      )
      .datePickerStyle(.compact)
      .labelsHidden()

      Spacer()

      // Repeat label + toggle
      Text("Repeat")
        .font(.subheadline)
        .fontWeight(.medium)

      Toggle(isOn: Binding(
        get: { isRepeating },
        set: { newValue in
          withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isRepeating = newValue
            if newValue {
              syncUIToRRule()
            } else {
              rruleString = ""
              onRRuleChange?("")
            }
          }
        }
      )) {
        EmptyView()
      }
      .toggleStyle(.switch)
      .labelsHidden()
    }
    .padding(12)
    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    .cornerRadius(8)
  }

  // MARK: - Recurrence Options (Collapsible)

  private var recurrenceOptionsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Collapsible header with summary
      collapsibleHeader
        .padding(16)

      // Expanded editing controls
      if isExpanded {
        Divider()
          .padding(.horizontal, 16)

        // 1. Repeat Pattern
        repeatPatternSection
          .padding(16)

        // 2. Pattern Specifics
        patternSpecificsSection
          .padding(.horizontal, 16)

        // More options toggle
        moreOptionsToggle
          .padding(.horizontal, 16)
          .padding(.bottom, 16)

        // Ends + Excluded Dates + Advanced (hidden by default)
        if showMoreOptions {
          Divider()
            .padding(.horizontal, 16)

          // 3. Ends
          endsSection
            .padding(16)
            .transition(.opacity.combined(with: .move(edge: .top)))

          // 4. Excluded Dates (if binding provided)
          if excludedDates != nil {
            Divider()
              .padding(.horizontal, 16)

            excludedDatesSection
              .padding(16)
              .transition(.opacity.combined(with: .move(edge: .top)))
          }

          Divider()
            .padding(.horizontal, 16)

          // Advanced RRule editor
          advancedEditorSection
            .padding(16)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
    }
    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
    )
  }

  // MARK: - Collapsible Header

  private var collapsibleHeader: some View {
    HStack(spacing: 12) {
      // Chevron indicator
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(width: 12)

      // Human-readable summary
      RRuleSummaryView(rruleString: rruleString, mode: .expanded)
        .frame(maxWidth: .infinity, alignment: .leading)

      // Edit/Done button
      Button(action: {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
          isExpanded.toggle()
        }
      }) {
        Text(isExpanded ? "Done" : "Edit")
          .font(.subheadline)
          .fontWeight(.medium)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        isExpanded.toggle()
      }
    }
  }

  // MARK: - More Options Toggle

  private var moreOptionsToggle: some View {
    Button(action: {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        showMoreOptions.toggle()
      }
    }) {
      HStack(spacing: 4) {
        Image(systemName: showMoreOptions ? "chevron.up" : "chevron.down")
          .font(.caption)
        Text(showMoreOptions ? "Less options" : "More options")
          .font(.caption)
      }
      .foregroundColor(.accentColor)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Repeat Pattern Section

  private var repeatPatternSection: some View {
    HStack(spacing: 12) {
      Text("Repeat every")
        .font(.body)

      TextField("", value: $interval, format: .number)
        .textFieldStyle(.roundedBorder)
        .frame(width: 60)
        .multilineTextAlignment(.center)
        .onChange(of: interval) { _, _ in syncUIToRRule() }

      Picker("", selection: $frequency) {
        Text("Minute").tag(RRule.Frequency.minutely)
        Text("Hour").tag(RRule.Frequency.hourly)
        Text("Day").tag(RRule.Frequency.daily)
        Text("Week").tag(RRule.Frequency.weekly)
        Text("Month").tag(RRule.Frequency.monthly)
        Text("Year").tag(RRule.Frequency.yearly)
      }
      .pickerStyle(.menu)
      .frame(width: 100)
      .onChange(of: frequency) { _, _ in syncUIToRRule() }

      Spacer()
    }
  }

  // MARK: - Pattern Specifics Section

  private var patternSpecificsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Frequency-specific controls
      Group {
        switch frequency {
        case .daily:
          dailyControls
        case .weekly:
          weeklyControls
        case .monthly:
          monthlyControls
        case .yearly:
          yearlyControls
        default:
          EmptyView()
        }
      }
      .transition(.opacity)

      // Time picker (for all frequencies)
      HStack(spacing: 8) {
        Text("At times")
          .font(.caption)
          .foregroundColor(.secondary)

        TimePickerList(times: $atTimes)
          .onChange(of: atTimes) { _, _ in syncUIToRRule() }
      }
    }
  }

  // MARK: - Frequency-Specific Controls

  private var dailyControls: some View {
    EmptyView() // Daily only needs time picker
  }

  private var weeklyControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repeat on")
        .font(.caption)
        .foregroundColor(.secondary)

      WeekdaySelector(selectedDays: $selectedWeekdays)
        .onChange(of: selectedWeekdays) { _, _ in syncUIToRRule() }
    }
  }

  private var monthlyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Mode selector
      HStack(spacing: 20) {
        RadioButton(
          title: "Day of month",
          isSelected: monthlyMode == .dayOfMonth
        ) {
          withAnimation {
            monthlyMode = .dayOfMonth
            syncUIToRRule()
          }
        }

        RadioButton(
          title: "Day of week",
          isSelected: monthlyMode == .dayOfWeek
        ) {
          withAnimation {
            monthlyMode = .dayOfWeek
            syncUIToRRule()
          }
        }
      }

      // Mode-specific controls
      if monthlyMode == .dayOfMonth {
        MonthDaySelector(selectedDays: $selectedMonthDays)
          .onChange(of: selectedMonthDays) { _, _ in syncUIToRRule() }
      } else {
        OrdinalWeekdayPicker(
          ordinalPosition: $ordinalPosition,
          weekday: $ordinalWeekday
        )
        .onChange(of: ordinalPosition) { _, _ in syncUIToRRule() }
        .onChange(of: ordinalWeekday) { _, _ in syncUIToRRule() }
      }
    }
  }

  private var yearlyControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("In months")
          .font(.caption)
          .foregroundColor(.secondary)

        MonthSelector(selectedMonths: $selectedMonths)
          .onChange(of: selectedMonths) { _, _ in syncUIToRRule() }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("On days")
          .font(.caption)
          .foregroundColor(.secondary)

        MonthDaySelector(selectedDays: $selectedMonthDays)
          .onChange(of: selectedMonthDays) { _, _ in syncUIToRRule() }
      }
    }
  }

  // MARK: - Ends Section

  private var endsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ends")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      // After N occurrences
      HStack {
        Toggle(isOn: $useCount) {
          HStack(spacing: 8) {
            Text("After")
            TextField("", value: $countValue, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 60)
              .disabled(!useCount)
            Text("occurrences")
          }
        }
        .toggleStyle(.checkbox)
        .onChange(of: useCount) { _, _ in syncUIToRRule() }
        .onChange(of: countValue) { _, _ in syncUIToRRule() }

        Spacer()
      }

      // On specific date
      HStack {
        Toggle(isOn: $useUntil) {
          HStack(spacing: 8) {
            Text("On")
            DatePicker(
              "",
              selection: $untilDate,
              displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .disabled(!useUntil)
          }
        }
        .toggleStyle(.checkbox)
        .onChange(of: useUntil) { _, _ in syncUIToRRule() }
        .onChange(of: untilDate) { _, _ in syncUIToRRule() }

        Spacer()
      }
    }
  }

  // MARK: - Advanced Editor Section

  private var advancedEditorSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Advanced: Edit RRule")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      Text("RFC 5545 RRule Format")
        .font(.caption)
        .foregroundColor(.secondary)

      TextEditor(text: Binding(
        get: { rruleString },
        set: { newValue in
          rruleString = newValue
          onRRuleChange?(newValue)
        }
      ))
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .frame(minHeight: 80, maxHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.accentColor, lineWidth: 1)
        )

      Button("Parse & Apply") {
        withAnimation {
          syncRRuleToUI()
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
  }

  // MARK: - Excluded Dates Section

  private var excludedDatesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Excluded Dates")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)

        Spacer()

        Button(action: {
          guard var dates = excludedDates?.wrappedValue else { return }
          let formatter = ISO8601DateFormatter()
          let dateString = formatter.string(from: Date())
          dates.append(dateString)
          excludedDates?.wrappedValue = dates
          onExdatesChange?(dates)
        }) {
          Image(systemName: "plus.circle")
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
      }

      if let dates = excludedDates?.wrappedValue, !dates.isEmpty {
        ForEach(dates, id: \.self) { exdate in
          HStack {
            Text(formatExdate(exdate))
              .font(.caption)

            Spacer()

            Button(action: {
              guard var dates = excludedDates?.wrappedValue else { return }
              dates.removeAll { $0 == exdate }
              excludedDates?.wrappedValue = dates
              onExdatesChange?(dates)
            }) {
              Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
          .cornerRadius(6)
        }
      } else {
        Text("No excluded dates")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Helper Methods

  private func formatExdate(_ exdate: String) -> String {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: exdate) {
      let displayFormatter = DateFormatter()
      displayFormatter.dateStyle = .medium
      displayFormatter.timeStyle = .short
      return displayFormatter.string(from: date)
    }
    return exdate
  }

  // MARK: - Sync Methods

  /// Build RRule string from UI state
  private func syncUIToRRule() {
    guard isRepeating else {
      rruleString = ""
      onRRuleChange?("")
      return
    }

    var rrule = RRule(freq: frequency, interval: interval)

    // Extract hours and minutes from times
    let calendar = Calendar.current
    rrule.byhour = atTimes.map { calendar.component(.hour, from: $0) }
    rrule.byminute = Array(Set(atTimes.map { calendar.component(.minute, from: $0) }))

    // Frequency-specific
    switch frequency {
    case .weekly:
      rrule.byday = Array(selectedWeekdays)
    case .monthly:
      if monthlyMode == .dayOfMonth {
        rrule.bymonthday = Array(selectedMonthDays)
      } else {
        rrule.byday = [ordinalWeekday]
        // Note: BYSETPOS would need to be added to RRule model
        // For now, we encode it in a way the backend understands
      }
    case .yearly:
      rrule.bymonth = Array(selectedMonths)
      rrule.bymonthday = Array(selectedMonthDays)
    default:
      break
    }

    // Ends
    if useCount {
      rrule.count = countValue
    }
    if useUntil {
      rrule.until = untilDate
    }

    let newRRule = rrule.toRRuleString()
    if newRRule != rruleString {
      rruleString = newRRule
      onRRuleChange?(newRRule)
    }
  }

  /// Parse RRule string into UI state
  private func syncRRuleToUI() {
    // Empty RRule = one-time event
    guard !rruleString.isEmpty else {
      isRepeating = false
      return
    }

    isRepeating = true

    do {
      let rrule = try RRule.fromRRuleString(rruleString)

      frequency = rrule.freq
      interval = rrule.interval

      // Times
      if !rrule.byhour.isEmpty {
        let calendar = Calendar.current
        atTimes = rrule.byhour.map { hour in
          var components = calendar.dateComponents([.year, .month, .day], from: Date())
          components.hour = hour
          components.minute = rrule.byminute.first ?? 0
          return calendar.date(from: components) ?? Date()
        }
      }

      // Frequency-specific
      switch frequency {
      case .weekly:
        selectedWeekdays = Set(rrule.byday)
      case .monthly:
        if !rrule.bymonthday.isEmpty {
          monthlyMode = .dayOfMonth
          selectedMonthDays = Set(rrule.bymonthday)
        } else if !rrule.byday.isEmpty {
          monthlyMode = .dayOfWeek
          ordinalWeekday = rrule.byday.first ?? "MO"
          // BYSETPOS parsing would go here
        }
      case .yearly:
        selectedMonths = Set(rrule.bymonth)
        selectedMonthDays = Set(rrule.bymonthday)
      default:
        break
      }

      // Ends
      if let count = rrule.count {
        useCount = true
        countValue = count
      } else {
        useCount = false
      }

      if let until = rrule.until {
        useUntil = true
        untilDate = until
      } else {
        useUntil = false
      }

    } catch {
      print("Failed to parse RRule: \(error)")
    }
  }
}

// MARK: - Radio Button Component

private struct RadioButton: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isSelected ? "circle.inset.filled" : "circle")
          .foregroundColor(isSelected ? .accentColor : .secondary)
        Text(title)
          .foregroundColor(.primary)
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Preview

#Preview("One-time Event") {
  RecurrenceBuilder(
    rruleString: .constant(""),
    startDate: .constant(Date())
  )
  .padding()
  .frame(width: 500)
}

#Preview("Repeating Event") {
  RecurrenceBuilder(
    rruleString: .constant("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0"),
    startDate: .constant(Date())
  )
  .padding()
  .frame(width: 500)
}
