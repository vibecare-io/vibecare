import SwiftUI

/// Ordinal position for "day of week" monthly patterns
/// e.g., "First Monday", "Last Friday"
enum OrdinalPosition: Int, CaseIterable, Identifiable {
  case first = 1
  case second = 2
  case third = 3
  case fourth = 4
  case last = -1

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .first: return "First"
    case .second: return "Second"
    case .third: return "Third"
    case .fourth: return "Fourth"
    case .last: return "Last"
    }
  }
}

/// Picker for selecting ordinal weekday patterns like "First Monday of the month"
/// Used in monthly recurrence with BYSETPOS
struct OrdinalWeekdayPicker: View {
  @Binding var ordinalPosition: OrdinalPosition
  @Binding var weekday: String

  private let weekdays: [(display: String, code: String)] = [
    ("Sunday", "SU"),
    ("Monday", "MO"),
    ("Tuesday", "TU"),
    ("Wednesday", "WE"),
    ("Thursday", "TH"),
    ("Friday", "FR"),
    ("Saturday", "SA"),
  ]

  var body: some View {
    HStack(spacing: 12) {
      Picker("", selection: $ordinalPosition) {
        ForEach(OrdinalPosition.allCases) { position in
          Text(position.displayName).tag(position)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 100)

      Picker("", selection: $weekday) {
        ForEach(weekdays, id: \.code) { day in
          Text(day.display).tag(day.code)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 120)

      Text("of the month")
        .foregroundColor(.secondary)
    }
  }
}

#Preview {
  OrdinalWeekdayPicker(
    ordinalPosition: .constant(.first),
    weekday: .constant("MO")
  )
  .padding()
}
