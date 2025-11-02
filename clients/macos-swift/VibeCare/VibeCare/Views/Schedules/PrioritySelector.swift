import SwiftUI

/// Priority selector component for schedules
/// Provides visual dropdown picker with color indicators and icons
struct PrioritySelector: View {
    @Binding var priority: Priority
    let onChange: (Priority) -> Void

    var body: some View {
        Menu {
            ForEach(Priority.allCases, id: \.self) { level in
                Button {
                    priority = level
                    onChange(level)
                } label: {
                    Label {
                        Text(level.displayName)
                    } icon: {
                        Image(systemName: level == priority ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color(level.color))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                // Priority icon
                Circle()
                    .fill(Color(priority.color))
                    .frame(width: 8, height: 8)

                // Priority text
                Text(priority.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                // Dropdown chevron
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(priority.color).opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(priority.color).opacity(0.3), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .help("Set priority level")
    }
}

// MARK: - Compact Variant

/// Compact priority selector for inline use
struct PrioritySelectorCompact: View {
    @Binding var priority: Priority
    let onChange: (Priority) -> Void

    var body: some View {
        Picker("Priority", selection: $priority) {
            ForEach(Priority.allCases, id: \.self) { level in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(level.color))
                        .frame(width: 6, height: 6)
                    Text(level.displayName)
                }
                .tag(level)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: priority) { _, newValue in
            onChange(newValue)
        }
    }
}

// MARK: - Preview

#Preview("Priority Selector") {
    VStack(spacing: 24) {
        Text("Standard Priority Selector")
            .font(.headline)

        ForEach(Priority.allCases, id: \.self) { level in
            HStack {
                Text("\(level.displayName):")
                    .foregroundStyle(.secondary)
                Spacer()
                PrioritySelector(
                    priority: .constant(level),
                    onChange: { newPriority in
                        print("Priority changed to: \(newPriority)")
                    }
                )
            }
        }

        Divider()

        Text("Interactive Example")
            .font(.headline)

        PrioritySelectorDemo()
    }
    .padding()
    .frame(width: 350)
}

#Preview("Compact Priority Selector") {
    VStack(spacing: 16) {
        Text("Compact Variant")
            .font(.headline)

        ForEach(Priority.allCases, id: \.self) { level in
            HStack {
                Text("\(level.displayName):")
                Spacer()
                PrioritySelectorCompact(
                    priority: .constant(level),
                    onChange: { _ in }
                )
            }
        }
    }
    .padding()
    .frame(width: 300)
}

// MARK: - Preview Helper

private struct PrioritySelectorDemo: View {
    @State private var selectedPriority: Priority = .medium

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Current Priority:")
                    .foregroundStyle(.secondary)
                Spacer()
                PrioritySelector(
                    priority: $selectedPriority,
                    onChange: { newPriority in
                        print("Priority changed from \(selectedPriority) to \(newPriority)")
                    }
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Priority Level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedPriority.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Color")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Color(selectedPriority.color))
                        .frame(width: 20, height: 20)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}
