import SwiftUI

/// UI component for selecting countdown timer durations for one-shot templates
struct CountdownTimerPicker: View {
    @Binding var startDate: Date
    let countdownOptions: CountdownOptions?

    @State private var selectedMinutes: Int = 30
    @State private var isEditingValue: Bool = false
    @State private var editingMinutes: Int = 30
    @FocusState private var isTextFieldFocused: Bool

    /// Get presets from countdown options or use standard fallback
    private var options: CountdownOptions {
        countdownOptions ?? .standard
    }

    /// Presets as (minutes, label) tuples for the slider
    private var presets: [(minutes: Int, label: String)] {
        options.presets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader
            durationDisplayView
            nativeSliderView
            executionTimeDisplay
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .onAppear {
            // Initialize with default from options
            selectedMinutes = options.defaultMinutes
            updateStartDate(minutes: selectedMinutes)
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.headline)
                .foregroundColor(.accentColor)

            Text("Remind In")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption)
                Text("One-time")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
    }

    // MARK: - Duration Display (Double-Tap to Edit)

    private var durationDisplayView: some View {
        HStack {
            Spacer()
            if isEditingValue {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("", value: $editingMinutes, format: .number)
                        .font(.system(size: 36, weight: .semibold))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($isTextFieldFocused)
                        .onSubmit {
                            finishEditing()
                        }
                        .onAppear {
                            editingMinutes = selectedMinutes
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isTextFieldFocused = true
                            }
                        }

                    Text("minutes")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            } else {
                Text(formatDuration(selectedMinutes))
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(.primary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        isEditingValue = true
                    }
                    .help("Double-click to edit")
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Native Slider

    /// Find slider position for current selectedMinutes
    private var sliderPosition: Double {
        if let index = presets.firstIndex(where: { $0.minutes == selectedMinutes }) {
            return Double(index)
        }
        // For custom values not in presets, find closest
        let closest = presets.enumerated().min(by: {
            abs($0.element.minutes - selectedMinutes) < abs($1.element.minutes - selectedMinutes)
        })
        return Double(closest?.offset ?? 0)
    }

    private var nativeSliderView: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { sliderPosition },
                    set: { newValue in
                        let index = Int(newValue.rounded())
                        let clampedIndex = max(0, min(presets.count - 1, index))
                        selectedMinutes = presets[clampedIndex].minutes
                        updateStartDate(minutes: selectedMinutes)
                    }
                ),
                in: 0...Double(max(0, presets.count - 1)),
                step: 1
            )
            .tint(.green)
            .padding(.horizontal, 8)

            intervalLabelsView
        }
    }

    // MARK: - Interval Labels

    private var intervalLabelsView: some View {
        HStack(spacing: 0) {
            ForEach(0..<presets.count, id: \.self) { index in
                Text(presets[index].label)
                    .font(.caption2)
                    .foregroundColor(presets[index].minutes == selectedMinutes ? .accentColor : .secondary)
                    .fontWeight(presets[index].minutes == selectedMinutes ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Execution Time Display

    private var executionTimeDisplay: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(executionTimeText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.top, 4)
    }

    private var executionTimeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(startDate)
        let isTomorrow = calendar.isDateInTomorrow(startDate)

        let timeString = formatter.string(from: startDate)

        if isToday {
            return "Will execute at \(timeString) today"
        } else if isTomorrow {
            return "Will execute at \(timeString) tomorrow"
        } else {
            formatter.dateStyle = .short
            return "Will execute at \(formatter.string(from: startDate))"
        }
    }

    // MARK: - Helper Methods

    private func finishEditing() {
        // Clamp to reasonable range
        let maxMinutes = presets.last?.minutes ?? 120
        let clampedMinutes = max(1, min(maxMinutes * 2, editingMinutes))
        selectedMinutes = clampedMinutes
        updateStartDate(minutes: selectedMinutes)
        isEditingValue = false
        isTextFieldFocused = false
    }

    private func formatDuration(_ minutes: Int) -> String {
        CountdownOptions.label(for: minutes)
    }

    private func updateStartDate(minutes: Int) {
        startDate = Calendar.current.date(
            byAdding: .minute,
            value: minutes,
            to: Date()
        ) ?? Date()
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // With custom options (laundry)
        CountdownTimerPicker(
            startDate: .constant(Date()),
            countdownOptions: CountdownOptions(
                durations: [30, 45, 60, 90],
                defaultMinutes: 60
            )
        )

        // With standard fallback
        CountdownTimerPicker(
            startDate: .constant(Date()),
            countdownOptions: nil
        )
    }
    .padding(20)
    .frame(width: 600)
}
