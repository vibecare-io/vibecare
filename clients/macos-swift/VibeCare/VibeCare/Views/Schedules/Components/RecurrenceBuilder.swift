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

  // Optional: Next execution time for countdown display
  var nextExecution: Date?

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
  @State private var untilDate: Date =
    Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
  @State private var showAdvanced: Bool = false
  @State private var showMoreOptions: Bool = false  // For Ends + Advanced section
  @State private var editingRRule: String = ""
  @State private var hasInitialized: Bool = false
  @State private var isExpanded: Bool = false  // Collapsed by default, showing summary only
  @State private var debounceTask: Task<Void, Never>?  // For debouncing TextEditor changes
  @State private var rruleValidationError: String?  // Client-side validation error message

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Single unified card
      unifiedScheduleCard
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

  // MARK: - Unified Schedule Card (Single Row Header + Expandable Content)

  private var unifiedScheduleCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Single row header: chevron + summary + Edit/Done + Repeats toggle
      unifiedHeader
        .padding(12)

      // Expanded content (only when isExpanded)
      if isExpanded {
        Divider()
          .padding(.horizontal, 12)

        if isRepeating {
          expandedRecurrenceContent
        } else {
          expandedOneShotContent
        }
      }
    }
    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    .cornerRadius(8)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isExpanded ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
    )
  }

  // MARK: - Unified Header (Single Row)

  private var unifiedHeader: some View {
    HStack(spacing: 12) {
      // Chevron indicator
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(width: 12)

      // Summary text with countdown (always visible)
      HStack(spacing: 6) {
        if isRepeating {
          RRuleSummaryView(rruleString: rruleString, mode: .compact)
            .font(.subheadline)
            .fontWeight(.medium)

          // Always show countdown for recurring schedules
          if let countdown = countdownText {
            Text("•")
              .foregroundColor(.secondary)
            Text(countdown)
              .font(.subheadline)
              .foregroundColor(.green)
          }
        } else {
          // One-shot: "Will run at Nov 30, 3:00 PM • in 2 hours" or "Completed at Nov 28, 3:00 PM • 2 days ago"
          if let status = oneShotStatusText {
            Text(status.prefix)
              .font(.subheadline)
              .fontWeight(.medium)
            Text(formatOneShotDate(startDate))
              .font(.subheadline)
              .foregroundColor(.secondary)
            Text("•")
              .foregroundColor(.secondary)
            Text(status.text)
              .font(.subheadline)
              .foregroundColor(status.color)
          }
        }
      }
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

      // Divider
      Divider()
        .frame(height: 20)

      // Repeats label + toggle
      Text("Repeats")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      Toggle(
        isOn: Binding(
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
        )
      ) {
        EmptyView()
      }
      .toggleStyle(.switch)
      .labelsHidden()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
        isExpanded.toggle()
      }
    }
  }

  // MARK: - Expanded One-Shot Content

  private var expandedOneShotContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Text("Date & Time")
          .font(.subheadline)
          .fontWeight(.medium)

        DatePicker(
          "",
          selection: $startDate,
          displayedComponents: [.date, .hourAndMinute]
        )
        .datePickerStyle(.compact)
        .labelsHidden()

        Spacer()
      }
    }
    .padding(12)
  }

  // MARK: - Expanded Recurrence Content

  private var expandedRecurrenceContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repeat Pattern
      repeatPatternSection
        .padding(12)

      // Pattern Specifics
      patternSpecificsSection
        .padding(.horizontal, 12)

      // More options toggle
      moreOptionsToggle
        .padding(.horizontal, 12)
        .padding(.bottom, 12)

      // Start Date + Ends + Excluded Dates + Advanced (hidden by default)
      if showMoreOptions {
        Divider()
          .padding(.horizontal, 12)

        // Start Date (implementation detail, hidden in More options)
        startDateSection
          .padding(12)
          .transition(.opacity.combined(with: .move(edge: .top)))

        Divider()
          .padding(.horizontal, 12)

        // Ends
        endsSection
          .padding(12)
          .transition(.opacity.combined(with: .move(edge: .top)))

        // Excluded Dates (if binding provided)
        if excludedDates != nil {
          Divider()
            .padding(.horizontal, 12)

          excludedDatesSection
            .padding(12)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        Divider()
          .padding(.horizontal, 12)

        // Advanced RRule editor
        advancedEditorSection
          .padding(12)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  // MARK: - Countdown Helper

  private var countdownText: String? {
    guard let next = nextExecution else { return nil }
    let now = Date()

    // If next is in the past, show "overdue"
    if next < now {
      return "overdue"
    }

    let interval = next.timeIntervalSince(now)

    // Format countdown
    if interval < 60 {
      return "in \(Int(interval))s"
    } else if interval < 3600 {
      let minutes = Int(interval / 60)
      return "in \(minutes) min"
    } else if interval < 86400 {
      let hours = Int(interval / 3600)
      let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
      if minutes > 0 {
        return "in \(hours)h \(minutes)m"
      }
      return "in \(hours)h"
    } else {
      let days = Int(interval / 86400)
      return "in \(days) day\(days == 1 ? "" : "s")"
    }
  }

  private func formatOneShotDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  // MARK: - One-Shot Status Helper

  private var oneShotStatusText: (prefix: String, text: String, color: Color)? {
    let now = Date()

    // If startDate is in the future, show "Will run at ... • in X"
    if startDate > now {
      let interval = startDate.timeIntervalSince(now)
      let prefix = "Will run at"

      if interval < 60 {
        return (prefix, "in \(Int(interval))s", .green)
      } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return (prefix, "in \(minutes) min", .green)
      } else if interval < 86400 {
        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
        if minutes > 0 {
          return (prefix, "in \(hours)h \(minutes)m", .green)
        }
        return (prefix, "in \(hours)h", .green)
      } else {
        let days = Int(interval / 86400)
        return (prefix, "in \(days) day\(days == 1 ? "" : "s")", .green)
      }
    } else {
      // startDate is in the past - show "Completed at ... • X ago"
      let interval = now.timeIntervalSince(startDate)
      let prefix = "Completed at"

      if interval < 60 {
        return (prefix, "\(Int(interval))s ago", .secondary)
      } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return (prefix, "\(minutes) min ago", .secondary)
      } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return (prefix, "\(hours)h ago", .secondary)
      } else {
        let days = Int(interval / 86400)
        return (prefix, "\(days) day\(days == 1 ? "" : "s") ago", .secondary)
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

  // MARK: - Start Date Section (in More options)

  private var startDateSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Start Date")
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      HStack(spacing: 12) {
        DatePicker(
          "",
          selection: $startDate,
          displayedComponents: [.date]
        )
        .datePickerStyle(.compact)
        .labelsHidden()

        Spacer()
      }

      Text("The anchor point for calculating recurring occurrences")
        .font(.caption)
        .foregroundColor(.secondary)
    }
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

      // Time picker (only for daily and below frequencies)
      // High-frequency rules (minutely, hourly) don't support BYHOUR/BYMINUTE
      if frequency.supportsTimePicker {
        HStack(spacing: 8) {
          Text("At times")
            .font(.caption)
            .foregroundColor(.secondary)

          TimePickerList(times: $atTimes)
            .onChange(of: atTimes) { _, _ in syncUIToRRule() }
        }
      }
    }
  }

  // MARK: - Frequency-Specific Controls

  private var dailyControls: some View {
    EmptyView()  // Daily only needs time picker
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

      TextEditor(
        text: Binding(
          get: { rruleString },
          set: { newValue in
            rruleString = newValue
            // Validate immediately for UI feedback
            validateRRule(newValue)
            // Debounce: wait 500ms before firing callback to avoid hammering backend
            debounceTask?.cancel()
            debounceTask = Task {
              try? await Task.sleep(nanoseconds: 700_000_000)  // 700ms
              if !Task.isCancelled {
                await MainActor.run {
                  // Only fire callback if validation passes
                  if rruleValidationError == nil {
                    onRRuleChange?(newValue)
                  }
                }
              }
            }
          }
        )
      )
      .font(.system(.body, design: .monospaced))
      .padding(12)
      .background(Color(NSColor.textBackgroundColor))
      .frame(minHeight: 80, maxHeight: 120)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(rruleValidationError != nil ? Color.red : Color.accentColor, lineWidth: 1)
      )

      // Show validation error if present
      if let error = rruleValidationError {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)
          Text(error)
            .foregroundColor(.red)
        }
        .font(.caption)
      }

      Button("Parse & Apply") {
        withAnimation {
          syncRRuleToUI()
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(rruleValidationError != nil)
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

    // Extract hours and minutes from times (only for frequencies that support it)
    // High-frequency rules (minutely, hourly) should NOT have BYHOUR/BYMINUTE
    // as this causes CPU spikes in RRule calculation
    if frequency.supportsTimePicker {
      let calendar = Calendar.current
      rrule.byhour = atTimes.map { calendar.component(.hour, from: $0) }
      rrule.byminute = Array(Set(atTimes.map { calendar.component(.minute, from: $0) }))
    }

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

  // MARK: - RRule Validation

  /// Validates an RRule string and sets rruleValidationError if invalid.
  /// Uses the strict parser and checks for problematic patterns.
  private func validateRRule(_ rruleString: String) {
    guard !rruleString.isEmpty else {
      rruleValidationError = nil
      return
    }

    do {
      let rrule = try RRule.fromRRuleString(rruleString)

      // Check for problematic patterns: high-frequency + time constraints
      // These cause CPU spikes in RRule calculation on the backend
      if (rrule.freq == .minutely || rrule.freq == .hourly)
        && (!rrule.byhour.isEmpty || !rrule.byminute.isEmpty)
      {
        rruleValidationError = "High-frequency rules cannot use BYHOUR/BYMINUTE"
        return
      }

      rruleValidationError = nil
    } catch {
      rruleValidationError = error.localizedDescription
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
    startDate: .constant(Date()),
    nextExecution: Date().addingTimeInterval(3600) // 1 hour from now
  )
  .padding()
  .frame(width: 500)
}

#Preview("Repeating Event") {
  RecurrenceBuilder(
    rruleString: .constant("FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0"),
    startDate: .constant(Date()),
    nextExecution: Date().addingTimeInterval(1320) // 22 minutes from now
  )
  .padding()
  .frame(width: 500)
}
