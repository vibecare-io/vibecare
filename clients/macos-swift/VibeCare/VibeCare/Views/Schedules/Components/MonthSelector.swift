import SwiftUI

/// A grid of month buttons for selecting months of the year
/// Used in yearly recurrence patterns
struct MonthSelector: View {
  @Binding var selectedMonths: Set<Int>

  private let months = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 8) {
      ForEach(1...12, id: \.self) { month in
        Button(action: {
          if selectedMonths.contains(month) {
            selectedMonths.remove(month)
          } else {
            selectedMonths.insert(month)
          }
        }) {
          Text(months[month - 1])
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
              selectedMonths.contains(month)
                ? Color.accentColor
                : Color(NSColor.controlBackgroundColor)
            )
            .foregroundColor(selectedMonths.contains(month) ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

#Preview {
  MonthSelector(selectedMonths: .constant([1, 6, 12]))
    .padding()
    .frame(width: 300)
}
