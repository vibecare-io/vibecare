import SwiftUI

// MARK: - RRule Summary View

/// A reusable SwiftUI component that displays RRule schedules in human-readable format.
/// Supports both compact (list view) and expanded (detail view) display modes.
struct RRuleSummaryView: View {
    let rruleString: String
    let mode: DisplayMode

    enum DisplayMode {
        case compact    // For list view - e.g., "Daily, 9:00 AM"
        case expanded   // For detail view - e.g., "Runs daily at 9:00 AM"
    }

    init(rruleString: String, mode: DisplayMode = .compact) {
        self.rruleString = rruleString
        self.mode = mode
    }

    var body: some View {
        Group {
            if let summary = formatRRule() {
                Text(summary)
                    .font(mode == .compact ? .caption : .body)
                    .foregroundColor(mode == .compact ? .secondary : .primary)
            } else {
                Text(mode == .compact ? "Invalid schedule" : "Invalid schedule format")
                    .font(mode == .compact ? .caption : .body)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    // MARK: - Formatting Logic

    private func formatRRule() -> String? {
        guard let rrule = try? RRule.fromRRuleString(rruleString) else {
            return nil
        }

        switch mode {
        case .compact:
            return formatCompact(rrule)
        case .expanded:
            return formatExpanded(rrule)
        }
    }

    // MARK: - Compact Format

    private func formatCompact(_ rrule: RRule) -> String {
        var parts: [String] = []

        // Frequency with special handling for common patterns
        if rrule.freq == .weekly && !rrule.byday.isEmpty {
            if rrule.byday.sorted() == ["FR", "MO", "TH", "TU", "WE"] {
                parts.append("Weekdays")
            } else if rrule.byday.sorted() == ["SA", "SU"] {
                parts.append("Weekends")
            } else if rrule.byday.count == 1 {
                parts.append(formatShortDay(rrule.byday[0]))
            } else {
                parts.append(rrule.byday.map { formatShortDay($0) }.joined(separator: ", "))
            }
        } else if rrule.freq == .daily {
            parts.append("Daily")
        } else if rrule.freq == .monthly {
            if let day = rrule.bymonthday.first {
                parts.append("Monthly on \(day)")
            } else {
                parts.append("Monthly")
            }
        } else if rrule.freq == .yearly {
            parts.append("Yearly")
        } else {
            parts.append(rrule.freq.displayName)
        }

        // Time
        if let time = formatTime(rrule) {
            parts.append(time)
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Expanded Format

    private func formatExpanded(_ rrule: RRule) -> String {
        var description = "Runs "

        // Frequency and interval
        if rrule.interval == 1 {
            description += rrule.freq.displayName.lowercased()
        } else {
            description += "every \(rrule.interval) \(pluralizeFrequency(rrule.freq))"
        }

        // Day specification
        if rrule.freq == .weekly && !rrule.byday.isEmpty {
            description += " on "
            if rrule.byday.sorted() == ["FR", "MO", "TH", "TU", "WE"] {
                description += "weekdays"
            } else if rrule.byday.sorted() == ["SA", "SU"] {
                description += "weekends"
            } else {
                description += rrule.byday.map { formatLongDay($0) }.joined(separator: ", ")
            }
        }

        // Month day specification
        if rrule.freq == .monthly && !rrule.bymonthday.isEmpty {
            let days = rrule.bymonthday.map { ordinal($0) }.joined(separator: ", ")
            description += " on the \(days)"
        }

        // Month specification for yearly
        if rrule.freq == .yearly && !rrule.bymonth.isEmpty {
            let months = rrule.bymonth.compactMap { monthName($0) }.joined(separator: ", ")
            description += " in \(months)"

            if let day = rrule.bymonthday.first {
                description += " on the \(ordinal(day))"
            }
        }

        // Time specification
        if let time = formatTime(rrule) {
            description += " at \(time)"
        }

        // Until/count constraints
        if let until = rrule.until {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            description += " until \(formatter.string(from: until))"
        } else if let count = rrule.count {
            description += " for \(count) occurrence\(count > 1 ? "s" : "")"
        }

        return description
    }

    // MARK: - Helper Methods

    private func formatTime(_ rrule: RRule) -> String? {
        guard !rrule.byhour.isEmpty else { return nil }

        let times = rrule.byhour.compactMap { hour -> String? in
            let minute = rrule.byminute.first ?? 0
            let formatter = DateFormatter()
            formatter.timeStyle = .short

            guard let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
                return nil
            }

            return formatter.string(from: date)
        }

        if times.count > 3 {
            return "\(times.count) times daily"
        }

        return times.joined(separator: ", ")
    }

    private func formatShortDay(_ dayCode: String) -> String {
        switch dayCode {
        case "MO": return "Mon"
        case "TU": return "Tue"
        case "WE": return "Wed"
        case "TH": return "Thu"
        case "FR": return "Fri"
        case "SA": return "Sat"
        case "SU": return "Sun"
        default: return dayCode
        }
    }

    private func formatLongDay(_ dayCode: String) -> String {
        switch dayCode {
        case "MO": return "Monday"
        case "TU": return "Tuesday"
        case "WE": return "Wednesday"
        case "TH": return "Thursday"
        case "FR": return "Friday"
        case "SA": return "Saturday"
        case "SU": return "Sunday"
        default: return dayCode
        }
    }

    private func pluralizeFrequency(_ freq: RRule.Frequency) -> String {
        switch freq {
        case .yearly: return "years"
        case .monthly: return "months"
        case .weekly: return "weeks"
        case .daily: return "days"
        case .hourly: return "hours"
        case .minutely: return "minutes"
        }
    }

    private func ordinal(_ number: Int) -> String {
        let suffix: String
        let mod100 = abs(number) % 100
        let mod10 = abs(number) % 10

        if mod100 >= 11 && mod100 <= 13 {
            suffix = "th"
        } else if mod10 == 1 {
            suffix = "st"
        } else if mod10 == 2 {
            suffix = "nd"
        } else if mod10 == 3 {
            suffix = "rd"
        } else {
            suffix = "th"
        }

        return "\(number)\(suffix)"
    }

    private func monthName(_ month: Int) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"

        guard let date = Calendar.current.date(from: DateComponents(year: 2025, month: month, day: 1)) else {
            return nil
        }

        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview("Compact Mode") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Compact Display Mode").font(.headline)

        Group {
            RRuleSummaryView(rruleString: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=DAILY;BYHOUR=7,12,19;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=16;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=TU,TH;BYHOUR=14;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=MONTHLY;BYDAY=-1MO;BYHOUR=9;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0", mode: .compact)
            RRuleSummaryView(rruleString: "INVALID_RRULE", mode: .compact)
        }
    }
    .padding()
    .frame(width: 400)
}

#Preview("Expanded Mode") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Expanded Display Mode").font(.headline)

        Group {
            RRuleSummaryView(rruleString: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=DAILY;BYHOUR=7,12,19;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=16;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=FR;BYHOUR=7;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=TU,TH;BYHOUR=14;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0", mode: .expanded)
            RRuleSummaryView(rruleString: "INVALID_RRULE", mode: .expanded)
        }
    }
    .padding()
    .frame(width: 500)
}

#Preview("Mixed Usage") {
    VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schedule Card").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Standup")
                        .font(.body)
                        .fontWeight(.medium)
                    RRuleSummaryView(rruleString: "FREQ=DAILY;BYHOUR=9;BYMINUTE=30", mode: .compact)
                }
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Schedule Detail").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Weekly Team Sync")
                    .font(.title3)
                    .fontWeight(.semibold)
                RRuleSummaryView(rruleString: "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=14;BYMINUTE=0", mode: .expanded)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
    }
    .padding()
    .frame(width: 400)
}
