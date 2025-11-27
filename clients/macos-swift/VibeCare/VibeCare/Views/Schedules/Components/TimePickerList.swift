import SwiftUI

/// A horizontal flow of time pickers with add/remove functionality
/// Used to specify multiple times for a recurrence pattern
struct TimePickerList: View {
  @Binding var times: [Date]

  var body: some View {
    // Use FlowLayout-like horizontal wrapping via LazyVGrid
    let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)]

    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      ForEach(Array(times.enumerated()), id: \.offset) { index, time in
        HStack(spacing: 4) {
          DatePicker(
            "",
            selection: Binding(
              get: { time },
              set: { times[index] = $0 }
            ),
            displayedComponents: [.hourAndMinute]
          )
          .datePickerStyle(.compact)
          .labelsHidden()

          if times.count > 1 {
            Button(action: {
              times.remove(at: index)
            }) {
              Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
      }

      // Add time button inline with time pickers
      Button(action: {
        // Add a new time, default to next hour
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: Date())
        components.hour = (components.hour ?? 9) + times.count
        components.minute = 0
        if let newTime = calendar.date(from: components) {
          times.append(newTime)
        } else {
          times.append(Date())
        }
      }) {
        HStack(spacing: 4) {
          Image(systemName: "plus.circle.fill")
          Text("Add time")
        }
        .font(.subheadline)
        .foregroundColor(.accentColor)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
  }
}

#Preview {
  TimePickerList(times: .constant([Date()]))
    .padding()
    .frame(width: 300)
}
