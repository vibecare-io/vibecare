import Foundation
import VCStubs

/// Represents an action template that will be created with the schedule
struct ActionTemplate: Identifiable, Equatable {
    let id = UUID()
    let type: ActionType
    let name: String
    let parameters: [String: String]

    /// Convert to an Action model
    func toAction(profileId: String, routineName: String, scheduleName: String) -> Action {
        var finalParams = parameters

        // Replace placeholders in parameters
        for (key, value) in finalParams {
            finalParams[key] = value
                .replacingOccurrences(of: "{routine}", with: routineName)
                .replacingOccurrences(of: "{schedule}", with: scheduleName)
        }

        return Action(
            profileId: profileId,
            type: type,
            name: name,
            description: "",
            parameters: finalParams,
            enabled: true
        )
    }
}

/// Combined template for creating a routine + schedule + actions in one flow
struct RoutineScheduleTemplate: Identifiable, Hashable {
    let id: String
    let category: TemplateCategory
    let routineName: String
    let routineDescription: String
    let routineIcon: String
    let routineColor: String
    let scheduleName: String
    let scheduleDescription: String
    let rruleString: String
    let defaultTimes: [TimeComponents] // Store as hour/minute components
    let suggestedActions: [ActionTemplate]
    let notificationIconId: String? // Backend SVG icon ID for template preview

    init(
        id: String,
        category: TemplateCategory,
        routineName: String,
        routineDescription: String = "",
        routineIcon: String,
        routineColor: String = "blue",
        scheduleName: String,
        scheduleDescription: String = "",
        rruleString: String,
        defaultTimes: [TimeComponents] = [TimeComponents(hour: 9, minute: 0)],
        suggestedActions: [ActionTemplate] = [],
        notificationIconId: String? = nil
    ) {
        self.id = id
        self.category = category
        self.routineName = routineName
        self.routineDescription = routineDescription
        self.routineIcon = routineIcon
        self.routineColor = routineColor
        self.scheduleName = scheduleName
        self.scheduleDescription = scheduleDescription
        self.rruleString = rruleString
        self.defaultTimes = defaultTimes
        self.suggestedActions = suggestedActions
        self.notificationIconId = notificationIconId
    }

    /// Initialize from protobuf message
    init(from proto: VCScheduleTemplate) {
        self.id = proto.id
        self.category = TemplateCategory(from: proto.category)
        self.routineName = proto.routineName
        self.routineDescription = proto.routineDescription
        self.routineIcon = proto.routineIcon
        self.routineColor = proto.routineColor
        self.scheduleName = proto.scheduleName
        self.scheduleDescription = proto.scheduleDescription
        self.rruleString = proto.rrule

        // Parse default times from "HH:MM" format
        self.defaultTimes = proto.defaultTimes.compactMap { timeString in
            let parts = timeString.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else {
                return nil
            }
            return TimeComponents(hour: hour, minute: minute)
        }

        // Convert notification config to action template
        var actions: [ActionTemplate] = []
        var iconId: String? = nil
        if proto.hasNotification {
            let notif = proto.notification

            // Extract icon ID for template preview
            if !notif.iconID.isEmpty {
                iconId = notif.iconID
            }

            // Build full backend URL for icon (if icon ID provided)
            var parameters: [String: String] = [
                "title": notif.title,
                "body": notif.body,
                "position": notif.position,
                "auto_dismiss_after": String(notif.autoDismiss),
                "width": String(notif.width),
                "height": String(notif.height)
            ]

            // Add icon URL if icon ID is provided
            if !notif.iconID.isEmpty {
                parameters["svg_path"] = NetworkConfiguration.buildIconURL(iconId: notif.iconID)
            }

            let actionTemplate = ActionTemplate(
                type: .notification,
                name: notif.title,
                parameters: parameters
            )
            actions.append(actionTemplate)
        }
        self.suggestedActions = actions
        self.notificationIconId = iconId
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RoutineScheduleTemplate, rhs: RoutineScheduleTemplate) -> Bool {
        lhs.id == rhs.id
    }
}

/// Time components for template default times
struct TimeComponents: Equatable {
    let hour: Int
    let minute: Int

    /// Convert to Date (today at this time)
    func toDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
}

/// Template categories for organization
enum TemplateCategory: String, CaseIterable {
    case daily = "Daily Routines"
    case weekly = "Weekly Routines"
    case monthlyYearly = "Monthly/Yearly"

    var icon: String {
        switch self {
        case .daily: return "sun.max.fill"
        case .weekly: return "calendar.badge.clock"
        case .monthlyYearly: return "calendar"
        }
    }

    /// Convert to protobuf enum
    func toProto() -> VCTemplateCategory {
        switch self {
        case .daily:
            return .daily
        case .weekly:
            return .weekly
        case .monthlyYearly:
            return .monthlyYearly
        }
    }

    /// Initialize from protobuf enum
    init(from proto: VCTemplateCategory) {
        switch proto {
        case .daily:
            self = .daily
        case .weekly:
            self = .weekly
        case .monthlyYearly:
            self = .monthlyYearly
        case .UNRECOGNIZED, .unspecified:
            self = .daily
        }
    }
}

// MARK: - Template Library

extension RoutineScheduleTemplate {
    /// All available templates organized by category
    static var library: [TemplateCategory: [RoutineScheduleTemplate]] {
        let templates = TemplateConfigLoader.shared.loadTemplates()
        return Dictionary(grouping: templates) { $0.category }
    }

    /// Get all templates as a flat array (loaded from JSON config)
    static var allTemplates: [RoutineScheduleTemplate] {
        TemplateConfigLoader.shared.loadTemplates()
    }

    /// Search templates by name or description
    static func search(_ query: String) -> [RoutineScheduleTemplate] {
        guard !query.isEmpty else { return allTemplates }

        let lowercased = query.lowercased()
        return allTemplates.filter {
            $0.routineName.lowercased().contains(lowercased) ||
            $0.scheduleName.lowercased().contains(lowercased) ||
            $0.routineDescription.lowercased().contains(lowercased)
        }
    }
}

// MARK: - Deprecated: Hardcoded Templates (Now loaded from JSON)

// The templates below are deprecated and kept for reference only.
// All templates are now loaded from TemplateConfigs.json via TemplateConfigLoader.
// To modify templates, edit the JSON file instead of this Swift code.

/*
extension RoutineScheduleTemplate {
    static let dailyTemplates: [RoutineScheduleTemplate] = [
        RoutineScheduleTemplate(
            id: "walk-pets",
            category: .daily,
            routineName: "Walk the Pets",
            routineDescription: "Daily dog walking routine",
            routineIcon: "pawprint.fill",
            routineColor: "brown",
            scheduleName: "Morning & Evening Walks",
            scheduleDescription: "Take the dogs out twice daily",
            rruleString: "FREQ=DAILY;INTERVAL=1",
            defaultTimes: [
                TimeComponents(hour: 7, minute: 0),
                TimeComponents(hour: 18, minute: 0)
            ],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Walk Reminder",
                    parameters: [
                        "title": "🐾 Time to Walk the Pets",
                        "body": "The dogs are waiting!",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "pushups",
            category: .daily,
            routineName: "Pushups 3x/day",
            routineDescription: "Quick exercise breaks throughout the day",
            routineIcon: "figure.strengthtraining.traditional",
            routineColor: "red",
            scheduleName: "Morning, Noon, Evening",
            scheduleDescription: "3 sets of pushups daily",
            rruleString: "FREQ=DAILY;INTERVAL=1",
            defaultTimes: [
                TimeComponents(hour: 8, minute: 0),
                TimeComponents(hour: 13, minute: 0),
                TimeComponents(hour: 19, minute: 0)
            ],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Exercise Break",
                    parameters: [
                        "title": "💪 Pushup Time!",
                        "body": "Drop and give me 20!",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "pick-up-kids",
            category: .daily,
            routineName: "Pick Up Kids",
            routineDescription: "School pickup routine",
            routineIcon: "figure.2.and.child.holdinghands",
            routineColor: "orange",
            scheduleName: "Afternoon Pickup",
            scheduleDescription: "Daily school pickup reminder",
            rruleString: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
            defaultTimes: [TimeComponents(hour: 15, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Pickup Reminder",
                    parameters: [
                        "title": "🚗 Time to Pick Up the Kids",
                        "body": "Leave in 10 minutes to be on time",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "morning-routine",
            category: .daily,
            routineName: "Morning Routine",
            routineDescription: "Start your day right",
            routineIcon: "sunrise.fill",
            routineColor: "yellow",
            scheduleName: "Daily at 6 AM",
            scheduleDescription: "Morning wake-up and prep",
            rruleString: "FREQ=DAILY;INTERVAL=1",
            defaultTimes: [TimeComponents(hour: 6, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Good Morning",
                    parameters: [
                        "title": "☀️ Good Morning!",
                        "body": "Time to start your day",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "hydration-reminder",
            category: .daily,
            routineName: "Hydration Master",
            routineDescription: "Stay hydrated throughout the day",
            routineIcon: "drop.fill",
            routineColor: "blue",
            scheduleName: "Every 2 Hours",
            scheduleDescription: "Drink water regularly",
            rruleString: "FREQ=HOURLY;INTERVAL=2",
            defaultTimes: [
                TimeComponents(hour: 9, minute: 0),
                TimeComponents(hour: 11, minute: 0),
                TimeComponents(hour: 13, minute: 0),
                TimeComponents(hour: 15, minute: 0),
                TimeComponents(hour: 17, minute: 0)
            ],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Hydration Check",
                    parameters: [
                        "title": "💧 Hydration Time",
                        "body": "Drink a glass of water!",
                        "sound": "default"
                    ]
                )
            ]
        )
    ]
}

// MARK: - Weekly Templates

extension RoutineScheduleTemplate {
    static let weeklyTemplates: [RoutineScheduleTemplate] = [
        RoutineScheduleTemplate(
            id: "check-mailbox",
            category: .weekly,
            routineName: "Check Mailbox",
            routineDescription: "Regular mail collection",
            routineIcon: "envelope.fill",
            routineColor: "blue",
            scheduleName: "Daily at 4 PM",
            scheduleDescription: "Check mail every day",
            rruleString: "FREQ=DAILY;INTERVAL=1",
            defaultTimes: [TimeComponents(hour: 16, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Mail Check",
                    parameters: [
                        "title": "📬 Check the Mailbox",
                        "body": "Time to collect today's mail",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "take-out-trash",
            category: .weekly,
            routineName: "Take Out Trash",
            routineDescription: "Weekly garbage collection",
            routineIcon: "trash.fill",
            routineColor: "gray",
            scheduleName: "Every Sunday Evening",
            scheduleDescription: "Prepare trash for Monday pickup",
            rruleString: "FREQ=WEEKLY;BYDAY=SU",
            defaultTimes: [TimeComponents(hour: 19, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Trash Reminder",
                    parameters: [
                        "title": "🗑️ Take Out the Trash",
                        "body": "Move bins to curb for tomorrow's pickup",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "security-training",
            category: .weekly,
            routineName: "Security Training",
            routineDescription: "Weekly security awareness",
            routineIcon: "shield.fill",
            routineColor: "indigo",
            scheduleName: "Every Friday at 3 PM",
            scheduleDescription: "Complete security module",
            rruleString: "FREQ=WEEKLY;BYDAY=FR",
            defaultTimes: [TimeComponents(hour: 15, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Training Due",
                    parameters: [
                        "title": "🛡️ Security Training",
                        "body": "Complete this week's security module",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "groceries",
            category: .weekly,
            routineName: "Groceries",
            routineDescription: "Weekly shopping trip",
            routineIcon: "cart.fill",
            routineColor: "green",
            scheduleName: "Weekly on Saturday",
            scheduleDescription: "Grocery shopping reminder",
            rruleString: "FREQ=WEEKLY;BYDAY=SA",
            defaultTimes: [TimeComponents(hour: 10, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Shopping Reminder",
                    parameters: [
                        "title": "🛒 Grocery Shopping",
                        "body": "Time for your weekly grocery run",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "bathroom-cleanup",
            category: .weekly,
            routineName: "Bathroom Cleanup",
            routineDescription: "Weekly bathroom deep clean",
            routineIcon: "sparkles",
            routineColor: "cyan",
            scheduleName: "Every Saturday Morning",
            scheduleDescription: "Deep clean bathroom",
            rruleString: "FREQ=WEEKLY;BYDAY=SA",
            defaultTimes: [TimeComponents(hour: 9, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Cleaning Time",
                    parameters: [
                        "title": "✨ Bathroom Cleaning",
                        "body": "Time for weekly bathroom cleanup",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "weekly-review",
            category: .weekly,
            routineName: "Weekly Review",
            routineDescription: "Reflect on the week",
            routineIcon: "list.bullet.clipboard.fill",
            routineColor: "purple",
            scheduleName: "Sunday Evening",
            scheduleDescription: "Review week and plan ahead",
            rruleString: "FREQ=WEEKLY;BYDAY=SU",
            defaultTimes: [TimeComponents(hour: 18, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Review Time",
                    parameters: [
                        "title": "📋 Weekly Review",
                        "body": "Take time to reflect on the week",
                        "sound": "default"
                    ]
                )
            ]
        )
    ]
}

// MARK: - Monthly/Yearly Templates

extension RoutineScheduleTemplate {
    static let monthlyYearlyTemplates: [RoutineScheduleTemplate] = [
        RoutineScheduleTemplate(
            id: "rent-reminder",
            category: .monthlyYearly,
            routineName: "Rent Reminder",
            routineDescription: "Monthly rent payment",
            routineIcon: "dollarsign.circle.fill",
            routineColor: "green",
            scheduleName: "1st of Every Month",
            scheduleDescription: "Pay monthly rent",
            rruleString: "FREQ=MONTHLY;BYMONTHDAY=1",
            defaultTimes: [TimeComponents(hour: 9, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Rent Due",
                    parameters: [
                        "title": "💰 Rent Payment Due",
                        "body": "Don't forget to pay rent today",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "birthday-reminder",
            category: .monthlyYearly,
            routineName: "Birthday Reminders",
            routineDescription: "Never miss a birthday",
            routineIcon: "birthday.cake.fill",
            routineColor: "pink",
            scheduleName: "Important Birthdays",
            scheduleDescription: "Track family birthdays",
            rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1",
            defaultTimes: [TimeComponents(hour: 9, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Birthday Alert",
                    parameters: [
                        "title": "🎂 Birthday Coming Up",
                        "body": "Someone's birthday is today!",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "anniversary",
            category: .monthlyYearly,
            routineName: "Anniversary",
            routineDescription: "Special date reminder",
            routineIcon: "heart.fill",
            routineColor: "red",
            scheduleName: "Annual Anniversary",
            scheduleDescription: "Important anniversary reminder",
            rruleString: "FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1",
            defaultTimes: [TimeComponents(hour: 8, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Anniversary Alert",
                    parameters: [
                        "title": "❤️ Happy Anniversary!",
                        "body": "Don't forget your special day",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "declutter-clothes",
            category: .monthlyYearly,
            routineName: "Declutter Clothes",
            routineDescription: "Seasonal wardrobe refresh",
            routineIcon: "tshirt.fill",
            routineColor: "purple",
            scheduleName: "Quarterly Declutter",
            scheduleDescription: "Review and donate unused clothes",
            rruleString: "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=1",
            defaultTimes: [TimeComponents(hour: 10, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Declutter Time",
                    parameters: [
                        "title": "👕 Time to Declutter",
                        "body": "Review your wardrobe and donate unused items",
                        "sound": "default"
                    ]
                )
            ]
        ),

        RoutineScheduleTemplate(
            id: "car-maintenance",
            category: .monthlyYearly,
            routineName: "Car Maintenance",
            routineDescription: "Regular vehicle check",
            routineIcon: "car.fill",
            routineColor: "gray",
            scheduleName: "Monthly Check",
            scheduleDescription: "Oil change and maintenance",
            rruleString: "FREQ=MONTHLY;BYMONTHDAY=15",
            defaultTimes: [TimeComponents(hour: 9, minute: 0)],
            suggestedActions: [
                ActionTemplate(
                    type: .notification,
                    name: "Maintenance Due",
                    parameters: [
                        "title": "🚗 Car Maintenance",
                        "body": "Time to check your vehicle",
                        "sound": "default"
                    ]
                )
            ]
        )
    ]
}
*/
