import Foundation

struct Schedule: Identifiable, Codable, Equatable, Hashable {
    let id: String  // Client-authoritative ID for local-first architecture
    let profileId: String  // Direct profile reference for easier querying
    var routineId: String
    var name: String
    var rrule: String  // RFC 5545 RRule string
    var scheduleTimezone: String  // IANA timezone for RRule calculations (e.g., "America/Los_Angeles")
    var dtstart: Date
    var exdates: [String]
    var lastExecution: Date?
    var nextExecution: Date?  // Pre-calculated by backend
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
        scheduleTimezone: String = TimeZone.current.identifier,  // Default to system timezone
        dtstart: Date = Date(),
        exdates: [String] = [],
        lastExecution: Date? = nil,
        nextExecution: Date? = nil,
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
        self.scheduleTimezone = scheduleTimezone
        self.dtstart = dtstart
        self.exdates = exdates
        self.lastExecution = lastExecution
        self.nextExecution = nextExecution
        self.notes = notes
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Returns the TimeZone object for this schedule's timezone identifier
    var timeZone: TimeZone? {
        TimeZone(identifier: scheduleTimezone)
    }

    /// Returns a human-readable name for the schedule timezone
    var timeZoneDisplayName: String {
        timeZone?.localizedName(for: .standard, locale: .current) ?? scheduleTimezone
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

        /// Returns true if this frequency supports BYHOUR/BYMINUTE constraints.
        /// High-frequency rules (minutely, hourly) should NOT use time constraints
        /// as they cause CPU spikes in RRule calculation.
        var supportsTimePicker: Bool {
            switch self {
            case .daily, .weekly, .monthly, .yearly:
                return true
            case .minutely, .hourly:
                return false
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

    // Parse RFC 5545 RRule string into RRule struct with strict validation
    static func fromRRuleString(_ rruleString: String) throws -> RRule {
        var rrule = RRule()
        var hasFreq = false

        let validKeys = Set(["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE", "BYDAY",
                             "BYMONTHDAY", "BYMONTH", "UNTIL", "COUNT", "BYWEEKNO",
                             "BYYEARDAY", "WKST"])

        let components = rruleString.split(separator: ";")
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                throw RRuleError.invalidRRuleString
            }

            let key = String(parts[0]).uppercased()
            let value = String(parts[1])

            // Reject unknown keys
            guard validKeys.contains(key) else {
                throw RRuleError.unknownKey(key)
            }

            switch key {
            case "FREQ":
                guard let frequency = Frequency(rawValue: value.uppercased()) else {
                    throw RRuleError.invalidFrequency
                }
                rrule.freq = frequency
                hasFreq = true

            case "INTERVAL":
                guard let interval = Int(value), interval > 0 else {
                    throw RRuleError.invalidValue(key: "INTERVAL", value: value)
                }
                rrule.interval = interval

            case "BYHOUR":
                let hours = try value.split(separator: ",").map { h -> Int in
                    guard let hour = Int(h), hour >= 0 && hour <= 23 else {
                        throw RRuleError.invalidValue(key: "BYHOUR", value: String(h))
                    }
                    return hour
                }
                rrule.byhour = hours

            case "BYMINUTE":
                let mins = try value.split(separator: ",").map { m -> Int in
                    guard let min = Int(m), min >= 0 && min <= 59 else {
                        throw RRuleError.invalidValue(key: "BYMINUTE", value: String(m))
                    }
                    return min
                }
                rrule.byminute = mins

            case "BYDAY":
                let validDays = Set(["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
                let days = try value.split(separator: ",").map { d -> String in
                    let day = String(d).uppercased()
                    // Strip ordinal prefix (e.g., "1MO" -> "MO", "-1FR" -> "FR")
                    let dayCode = day.trimmingCharacters(in: CharacterSet(charactersIn: "-0123456789"))
                    guard validDays.contains(dayCode) else {
                        throw RRuleError.invalidValue(key: "BYDAY", value: String(d))
                    }
                    return day
                }
                rrule.byday = days

            case "BYMONTHDAY":
                let days = try value.split(separator: ",").map { d -> Int in
                    guard let day = Int(d), (day >= 1 && day <= 31) || (day >= -31 && day <= -1) else {
                        throw RRuleError.invalidValue(key: "BYMONTHDAY", value: String(d))
                    }
                    return day
                }
                rrule.bymonthday = days

            case "BYMONTH":
                let months = try value.split(separator: ",").map { m -> Int in
                    guard let month = Int(m), month >= 1 && month <= 12 else {
                        throw RRuleError.invalidValue(key: "BYMONTH", value: String(m))
                    }
                    return month
                }
                rrule.bymonth = months

            case "UNTIL":
                let formatter = ISO8601DateFormatter()
                rrule.until = formatter.date(from: value)
                // Note: Don't throw on invalid date, just leave nil (lenient for UNTIL)

            case "COUNT":
                guard let count = Int(value), count > 0 else {
                    throw RRuleError.invalidValue(key: "COUNT", value: value)
                }
                rrule.count = count

            case "BYWEEKNO":
                let weeks = try value.split(separator: ",").map { w -> Int in
                    guard let week = Int(w), (week >= 1 && week <= 53) || (week >= -53 && week <= -1) else {
                        throw RRuleError.invalidValue(key: "BYWEEKNO", value: String(w))
                    }
                    return week
                }
                rrule.byweekno = weeks

            case "BYYEARDAY":
                let days = try value.split(separator: ",").map { d -> Int in
                    guard let day = Int(d), (day >= 1 && day <= 366) || (day >= -366 && day <= -1) else {
                        throw RRuleError.invalidValue(key: "BYYEARDAY", value: String(d))
                    }
                    return day
                }
                rrule.byyearday = days

            case "WKST":
                let validDays = Set(["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
                guard validDays.contains(value.uppercased()) else {
                    throw RRuleError.invalidValue(key: "WKST", value: value)
                }
                rrule.wkst = value.uppercased()

            default:
                break
            }
        }

        guard hasFreq else {
            throw RRuleError.missingFrequency
        }

        return rrule
    }
}

enum RRuleError: LocalizedError {
    case invalidRRuleString
    case invalidFrequency
    case missingFrequency
    case invalidValue(key: String, value: String)
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidRRuleString:
            return "Invalid RRule format"
        case .invalidFrequency:
            return "Invalid frequency value"
        case .missingFrequency:
            return "RRule must contain FREQ"
        case .invalidValue(let key, let value):
            return "Invalid \(key) value: \(value)"
        case .unknownKey(let key):
            return "Unknown RRule key: \(key)"
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

    // nextExecution is now a stored property populated from backend
    // Removed local RRule calculation - backend provides pre-calculated value

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

