import SwiftUI

/// A horizontal row of day buttons for selecting weekdays
/// Used in weekly recurrence patterns
struct WeekdaySelector: View {
  @Binding var selectedDays: Set<String>

  private let weekdays: [(short: String, full: String)] = [
    ("S", "SU"),
    ("M", "MO"),
    ("T", "TU"),
    ("W", "WE"),
    ("T", "TH"),
    ("F", "FR"),
    ("S", "SA"),
  ]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(weekdays.enumerated()), id: \.offset) { index, day in
        Button(action: {
          if selectedDays.contains(day.full) {
            selectedDays.remove(day.full)
          } else {
            selectedDays.insert(day.full)
          }
        }) {
          Text(day.short)
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(width: 40, height: 40)
            .background(
              selectedDays.contains(day.full)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedDays.contains(day.full) ? .white : .primary)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

#Preview {
  WeekdaySelector(selectedDays: .constant(["MO", "WE", "FR"]))
    .padding()
}
