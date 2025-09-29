import Foundation

struct Schedule: Identifiable, Codable, Equatable, Hashable {
    var id: Int64 { scheduleId }  // Computed property for Identifiable
    let scheduleId: Int64
    let routineId: String
    var name: String?
    var recurrenceJSON: String
    var dtstart: Date?
    var exdates: [String]
    var lastExecution: Date?
    var notes: String?
    var enabled: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        scheduleId: Int64 = 0,
        routineId: String,
        name: String? = nil,
        recurrenceJSON: String,
        dtstart: Date? = nil,
        exdates: [String] = [],
        lastExecution: Date? = nil,
        notes: String? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.scheduleId = scheduleId
        self.routineId = routineId
        self.name = name
        self.recurrenceJSON = recurrenceJSON
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

    func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func fromJSON(_ json: String) throws -> RRule {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else {
            throw RRuleError.invalidJSON
        }
        return try decoder.decode(RRule.self, from: data)
    }
}

enum RRuleError: LocalizedError {
    case invalidJSON
    case invalidFrequency

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid RRule JSON format"
        case .invalidFrequency:
            return "Invalid frequency value"
        }
    }
}

// MARK: - Schedule Extensions
extension Schedule {
    var rrule: RRule? {
        try? RRule.fromJSON(recurrenceJSON)
    }

    var displayName: String {
        name ?? rrule?.humanReadableDescription ?? "Untitled Schedule"
    }

    var nextExecution: Date? {
        // This would be calculated based on the RRule and current time
        // For now, we'll return a placeholder
        guard let rrule = rrule else { return nil }
        let start = dtstart ?? Date()

        // Simplified next execution calculation
        switch rrule.freq {
        case .daily:
            return Calendar.current.date(byAdding: .day, value: rrule.interval, to: start)
        case .weekly:
            return Calendar.current.date(byAdding: .weekOfYear, value: rrule.interval, to: start)
        case .monthly:
            return Calendar.current.date(byAdding: .month, value: rrule.interval, to: start)
        case .yearly:
            return Calendar.current.date(byAdding: .year, value: rrule.interval, to: start)
        case .hourly:
            return Calendar.current.date(byAdding: .hour, value: rrule.interval, to: start)
        case .minutely:
            return Calendar.current.date(byAdding: .minute, value: rrule.interval, to: start)
        }
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
}

