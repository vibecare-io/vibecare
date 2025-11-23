import Foundation

struct Schedule: Identifiable, Codable, Equatable, Hashable {
    let id: String  // Client-authoritative ID for local-first architecture
    let profileId: String  // Direct profile reference for easier querying
    let routineId: String
    var name: String
    var rrule: String  // RFC 5545 RRule string
    var dtstart: Date
    var exdates: [String]
    var lastExecution: Date?
    var notes: String
    var enabled: Bool
    // Note: action associations are handled via schedule_actions join table
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        profileId: String,
        routineId: String,
        name: String,
        rrule: String,
        dtstart: Date = Date(),
        exdates: [String] = [],
        lastExecution: Date? = nil,
        notes: String = "",
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.routineId = routineId
        self.name = name
        self.rrule = rrule
        self.dtstart = dtstart
        self.exdates = exdates
        self.lastExecution = lastExecution
        self.notes = notes
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - RRule Support
struct RRule: Codable, Equatable, Hashable {
    var freq: Frequency
    var interval: Int
    var byhour: [Int]
    var byminute: [Int]
    var byday: [String]
    var bymonthday: [Int]
    var bymonth: [Int]
    var until: Date?
    var count: Int?
    var byweekno: [Int]
    var byyearday: [Int]
    var wkst: String

    init(
        freq: Frequency = .daily,
        interval: Int = 1,
        byhour: [Int] = [],
        byminute: [Int] = [],
        byday: [String] = [],
        bymonthday: [Int] = [],
        bymonth: [Int] = [],
        until: Date? = nil,
        count: Int? = nil,
        byweekno: [Int] = [],
        byyearday: [Int] = [],
        wkst: String = "MO"
    ) {
        self.freq = freq
        self.interval = interval
        self.byhour = byhour
        self.byminute = byminute
        self.byday = byday
        self.bymonthday = bymonthday
        self.bymonth = bymonth
        self.until = until
        self.count = count
        self.byweekno = byweekno
        self.byyearday = byyearday
        self.wkst = wkst
    }

    enum Frequency: String, Codable, CaseIterable {
        case yearly = "YEARLY"
        case monthly = "MONTHLY"
        case weekly = "WEEKLY"
        case daily = "DAILY"
        case hourly = "HOURLY"
        case minutely = "MINUTELY"

        var displayName: String {
            switch self {
            case .yearly: return "Yearly"
            case .monthly: return "Monthly"
            case .weekly: return "Weekly"
            case .daily: return "Daily"
            case .hourly: return "Hourly"
            case .minutely: return "Every Minute"
            }
        }
    }

    // Convert RRule struct to RFC 5545 string format
    func toRRuleString() -> String {
        var parts: [String] = []

        // FREQ is required
        parts.append("FREQ=\(freq.rawValue)")

        // INTERVAL
        if interval > 1 {
            parts.append("INTERVAL=\(interval)")
        }

        // BYHOUR
        if !byhour.isEmpty {
            parts.append("BYHOUR=\(byhour.map(String.init).joined(separator: ","))")
        }

        // BYMINUTE
        if !byminute.isEmpty {
            parts.append("BYMINUTE=\(byminute.map(String.init).joined(separator: ","))")
        }

        // BYDAY
        if !byday.isEmpty {
            parts.append("BYDAY=\(byday.joined(separator: ","))")
        }

        // BYMONTHDAY
        if !bymonthday.isEmpty {
            parts.append("BYMONTHDAY=\(bymonthday.map(String.init).joined(separator: ","))")
        }

        // BYMONTH
        if !bymonth.isEmpty {
            parts.append("BYMONTH=\(bymonth.map(String.init).joined(separator: ","))")
        }

        // UNTIL
        if let until = until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            parts.append("UNTIL=\(formatter.string(from: until))")
        }

        // COUNT
        if let count = count {
            parts.append("COUNT=\(count)")
        }

        // BYWEEKNO
        if !byweekno.isEmpty {
            parts.append("BYWEEKNO=\(byweekno.map(String.init).joined(separator: ","))")
        }

        // BYYEARDAY
        if !byyearday.isEmpty {
            parts.append("BYYEARDAY=\(byyearday.map(String.init).joined(separator: ","))")
        }

        // WKST
        if wkst != "MO" {
            parts.append("WKST=\(wkst)")
        }

        return parts.joined(separator: ";")
    }

    // Parse RFC 5545 RRule string into RRule struct
    static func fromRRuleString(_ rruleString: String) throws -> RRule {
        var rrule = RRule()

        let components = rruleString.split(separator: ";")
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).uppercased()
            let value = String(parts[1])

            switch key {
            case "FREQ":
                guard let frequency = Frequency(rawValue: value) else {
                    throw RRuleError.invalidFrequency
                }
                rrule.freq = frequency

            case "INTERVAL":
                rrule.interval = Int(value) ?? 1

            case "BYHOUR":
                rrule.byhour = value.split(separator: ",").compactMap { Int($0) }

            case "BYMINUTE":
                rrule.byminute = value.split(separator: ",").compactMap { Int($0) }

            case "BYDAY":
                rrule.byday = value.split(separator: ",").map { String($0) }

            case "BYMONTHDAY":
                rrule.bymonthday = value.split(separator: ",").compactMap { Int($0) }

            case "BYMONTH":
                rrule.bymonth = value.split(separator: ",").compactMap { Int($0) }

            case "UNTIL":
                let formatter = ISO8601DateFormatter()
                rrule.until = formatter.date(from: value)

            case "COUNT":
                rrule.count = Int(value)

            case "BYWEEKNO":
                rrule.byweekno = value.split(separator: ",").compactMap { Int($0) }

            case "BYYEARDAY":
                rrule.byyearday = value.split(separator: ",").compactMap { Int($0) }

            case "WKST":
                rrule.wkst = value

            default:
                break
            }
        }

        return rrule
    }
}

enum RRuleError: LocalizedError {
    case invalidRRuleString
    case invalidFrequency

    var errorDescription: String? {
        switch self {
        case .invalidRRuleString:
            return "Invalid RRule format (expected RFC 5545 format)"
        case .invalidFrequency:
            return "Invalid frequency value"
        }
    }
}

// MARK: - Schedule Extensions
extension Schedule {
    var parsedRRule: RRule? {
        try? RRule.fromRRuleString(rrule)
    }

    var displayName: String {
        if !name.isEmpty {
            return name
        }
        return parsedRRule?.humanReadableDescription ?? "Untitled Schedule"
    }

    var nextExecution: Date? {
        guard let rrule = parsedRRule else { return nil }

        let now = Date()
        let calendar = Calendar.current

        // Start from the most recent reference point (last execution or dtstart)
        var candidate = lastExecution ?? dtstart

        // Determine the time component to add based on frequency
        let component: Calendar.Component
        switch rrule.freq {
        case .minutely: component = .minute
        case .hourly: component = .hour
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        }

        // Keep adding intervals until we find the next occurrence after now
        while candidate <= now {
            guard let next = calendar.date(byAdding: component, value: rrule.interval, to: candidate) else {
                return nil
            }
            candidate = next
        }

        // Apply BYHOUR and BYMINUTE constraints if present
        if !rrule.byhour.isEmpty || !rrule.byminute.isEmpty {
            let hour = rrule.byhour.first ?? calendar.component(.hour, from: candidate)
            let minute = rrule.byminute.first ?? calendar.component(.minute, from: candidate)

            guard let adjusted = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: candidate
            ) else {
                return candidate
            }

            // If adjustment moved time backwards, keep the original
            candidate = adjusted > now ? adjusted : candidate
        }

        // Check UNTIL constraint
        if let until = rrule.until, candidate > until {
            return nil // No more occurrences
        }

        return candidate
    }

    var status: ScheduleStatus {
        if !enabled {
            return .disabled
        }

        guard let nextRun = nextExecution else {
            return .noSchedule
        }

        let now = Date()
        if nextRun < now {
            return .overdue
        } else if nextRun.timeIntervalSince(now) < 3600 { // Next hour
            return .upcoming
        } else {
            return .scheduled
        }
    }
}

enum ScheduleStatus {
    case scheduled
    case upcoming
    case overdue
    case disabled
    case noSchedule

    var color: String {
        switch self {
        case .scheduled: return "blue"
        case .upcoming: return "orange"
        case .overdue: return "red"
        case .disabled: return "gray"
        case .noSchedule: return "gray"
        }
    }

    var iconName: String {
        switch self {
        case .scheduled: return "clock"
        case .upcoming: return "clock.badge.exclamationmark"
        case .overdue: return "clock.badge.xmark"
        case .disabled: return "pause.circle"
        case .noSchedule: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - RRule Extensions
extension RRule {
    var humanReadableDescription: String {
        var parts: [String] = []

        // Frequency
        if interval == 1 {
            parts.append("Every \(freq.displayName.lowercased())")
        } else {
            parts.append("Every \(interval) \(freq.displayName.lowercased().dropLast())s")
        }

        // Time specification
        if !byhour.isEmpty && !byminute.isEmpty {
            let times = byhour.compactMap { hour in
                byminute.map { minute in
                    let formatter = DateFormatter()
                    formatter.timeStyle = .short
                    let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
                    return formatter.string(from: date)
                }
            }.flatMap { $0 }

            if !times.isEmpty {
                parts.append("at \(times.joined(separator: ", "))")
            }
        }

        // Days specification
        if !byday.isEmpty {
            let dayNames = byday.compactMap { dayCode in
                switch dayCode {
                case "MO": return "Monday"
                case "TU": return "Tuesday"
                case "WE": return "Wednesday"
                case "TH": return "Thursday"
                case "FR": return "Friday"
                case "SA": return "Saturday"
                case "SU": return "Sunday"
                default: return nil
                }
            }
            if !dayNames.isEmpty {
                parts.append("on \(dayNames.joined(separator: ", "))")
            }
        }

        // Until specification
        if let until = until {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            parts.append("until \(formatter.string(from: until))")
        }

        // Count specification
        if let count = count {
            parts.append("for \(count) times")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Execution Calculation

    func nextExecution(after date: Date) -> Date? {
        // Basic implementation - in production would use a proper RRule library
        let calendar = Calendar.current
        var nextDate = date

        switch freq {
        case .minutely:
            nextDate = calendar.date(byAdding: .minute, value: interval, to: nextDate) ?? nextDate
        case .hourly:
            nextDate = calendar.date(byAdding: .hour, value: interval, to: nextDate) ?? nextDate
        case .daily:
            nextDate = calendar.date(byAdding: .day, value: interval, to: nextDate) ?? nextDate
            if !byhour.isEmpty, let hour = byhour.first {
                nextDate = calendar.date(bySettingHour: hour, minute: byminute.first ?? 0, second: 0, of: nextDate) ?? nextDate
            }
        case .weekly:
            nextDate = calendar.date(byAdding: .weekOfYear, value: interval, to: nextDate) ?? nextDate
        case .monthly:
            nextDate = calendar.date(byAdding: .month, value: interval, to: nextDate) ?? nextDate
        case .yearly:
            nextDate = calendar.date(byAdding: .year, value: interval, to: nextDate) ?? nextDate
        }

        // Check count and until constraints
        if let until = until, nextDate > until {
            return nil
        }

        return nextDate
    }

    // MARK: - Common Templates

    static let templates: [String: RRule] = [
        "Every 20 minutes": RRule(freq: .minutely, interval: 20),
        "Every hour": RRule(freq: .hourly, interval: 1),
        "Every 2 hours": RRule(freq: .hourly, interval: 2),
        "Daily at 9 AM": RRule(freq: .daily, byhour: [9], byminute: [0]),
        "Daily at 2 PM": RRule(freq: .daily, byhour: [14], byminute: [0]),
        "Daily at 6 PM": RRule(freq: .daily, byhour: [18], byminute: [0]),
        "Weekdays at 9 AM": RRule(freq: .weekly, byhour: [9], byminute: [0], byday: ["MO", "TU", "WE", "TH", "FR"]),
        "Weekdays at 2 PM": RRule(freq: .weekly, byhour: [14], byminute: [0], byday: ["MO", "TU", "WE", "TH", "FR"]),
        "Weekly on Monday": RRule(freq: .weekly, byhour: [9], byminute: [0], byday: ["MO"]),
        "Weekly on Friday": RRule(freq: .weekly, byhour: [17], byminute: [0], byday: ["FR"]),
        "Monthly on 1st": RRule(freq: .monthly, byhour: [9], byminute: [0], bymonthday: [1]),
        "Monthly on 15th": RRule(freq: .monthly, byhour: [9], byminute: [0], bymonthday: [15])
    ]

    static var templateNames: [String] {
        return Array(templates.keys).sorted()
    }
}

// MARK: - Schedule Extensions

extension Schedule {
    // MARK: - Convenience Methods

    mutating func updateLastExecution(_ date: Date = Date()) {
        lastExecution = date
        updatedAt = Date()
    }

    func isActiveAt(_ date: Date) -> Bool {
        guard enabled else { return false }

        // Check if date is in excluded dates
        let dateFormatter = ISO8601DateFormatter()
        let dateString = dateFormatter.string(from: date)
        return !exdates.contains(dateString)
    }

    var recurrenceRule: RRule? {
        get {
            return parsedRRule
        }
        set {
            if let rule = newValue {
                rrule = rule.toRRuleString()
                updatedAt = Date()
            }
        }
    }

    // MARK: - Factory Methods

    static func createFromTemplate(
        templateName: String,
        profileId: String,
        routineId: String,
        name: String? = nil
    ) -> Schedule? {
        guard let template = RRule.templates[templateName] else { return nil }

        return Schedule(
            profileId: profileId,
            routineId: routineId,
            name: name ?? templateName,
            rrule: template.toRRuleString(),
            dtstart: Date(),
            notes: "Created from template: \(templateName)"
        )
    }

    static func example(profileId: String, routineId: String) -> Schedule {
        return Schedule(
            profileId: profileId,
            routineId: routineId,
            name: "Every 20 minutes",
            rrule: "FREQ=MINUTELY;INTERVAL=20",
            dtstart: Date(),
            notes: "Regular notification reminder"
        )
    }
}

