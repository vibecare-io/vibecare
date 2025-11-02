import SwiftUI

/// A reusable component for displaying key-value pairs in detail views
struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        DetailRow(title: "Type", value: "Notification")
        DetailRow(title: "Status", value: "Active")
        DetailRow(title: "Created", value: "Jan 1, 2025")
        DetailRow(title: "Version", value: "1.0.0")
    }
    .padding()
    .frame(width: 400)
}
