import SwiftUI

struct TestingDetailView: View {
    let testResult: TestResult?

    var body: some View {
        Group {
            if let result = testResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Test Header
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.title)
                                    .foregroundColor(result.success ? .green : .red)

                                VStack(alignment: .leading) {
                                    Text("Test Result")
                                        .font(.largeTitle)
                                        .fontWeight(.bold)

                                    Text(result.name)
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }
                        }

                        Divider()

                        // Test Details
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(title: "Test", value: result.name)
                            DetailRow(title: "Status", value: result.success ? "Passed" : "Failed")
                            DetailRow(title: "Executed", value: DateFormatter.localizedString(from: result.timestamp, dateStyle: .medium, timeStyle: .long))
                            DetailRow(title: "Duration", value: String(format: "%.3f seconds", result.duration))
                        }

                        if !result.message.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text(result.success ? "Output" : "Error Message")
                                    .font(.headline)
                                    .foregroundColor(result.success ? .primary : .red)

                                Text(result.message)
                                    .font(.system(.body, design: .monospaced))
                                    .padding()
                                    .background(result.success ? Color.gray.opacity(0.1) : Color.red.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }


                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Test Details")
            } else {
                EmptyStateView(
                    title: "No Test Selected",
                    subtitle: "Run a test to see results here",
                    systemImage: "network.circle"
                )
            }
        }
    }
}


#Preview {
    TestingDetailView(testResult: TestResult(
        name: "Profile Service Connection",
        success: true,
        message: "Successfully connected to gRPC server",
        duration: 0.234,
        timestamp: Date()
    ))
}