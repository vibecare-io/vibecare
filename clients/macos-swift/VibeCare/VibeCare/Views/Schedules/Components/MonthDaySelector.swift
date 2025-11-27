import SwiftUI

/// A grid of day buttons (1-31) for selecting days of the month
/// Used in monthly recurrence patterns
struct MonthDaySelector: View {
  @Binding var selectedDays: Set<Int>

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...31, id: \.self) { day in
        Button(action: {
          if selectedDays.contains(day) {
            selectedDays.remove(day)
          } else {
            selectedDays.insert(day)
          }
        }) {
          Text("\(day)")
            .font(.caption)
            .fontWeight(.medium)
            .frame(width: 36, height: 36)
            .background(
              selectedDays.contains(day)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedDays.contains(day) ? .white : .primary)
            .cornerRadius(18)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

#Preview {
  MonthDaySelector(selectedDays: .constant([1, 15]))
    .padding()
    .frame(width: 300)
}
