import SwiftUI
import Logging

@available(macOS 15.0, *)
struct GRPCTestView: View {
    @Binding var selectedResult: TestResult?

    @State private var testResults: [TestResult] = []
    @State private var isRunning = false
    @State private var currentTest: String = ""
    @State private var hoveredResultId: UUID?

    private let logger = Logger(label: "grpc-test-view")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            testControls
            testResultsList
            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("gRPC Connection Tests")
                .font(.title)
                .fontWeight(.bold)

            Text("Test different gRPC-Swift 2 configurations to debug connection issues")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var testControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Run All Tests") {
                    Task {
                        await runAllTests()
                    }
                }
                .disabled(isRunning)

                Button("Clear Results") {
                    testResults.removeAll()
                }
                .disabled(isRunning)

                Spacer()

                if isRunning {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Running: \(currentTest)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            Text("Individual Tests:")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(TestType.allCases, id: \.rawValue) { testType in
                    Button(testType.rawValue) {
                        Task {
                            await runSingleTest(testType)
                        }
                    }
                    .disabled(isRunning)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var testResultsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !testResults.isEmpty {
                Text("Test Results:")
                    .font(.headline)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(testResults) { result in
                            TestResultRow(
                                result: result,
                                isSelected: selectedResult?.id == result.id,
                                isHovered: hoveredResultId == result.id,
                                onSelect: {
                                    selectedResult = result
                                }
                            )
                            .onHover { isHovered in
                                hoveredResultId = isHovered ? result.id : nil
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                Text("No test results yet. Run tests to see results here.")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
    }

    private func runAllTests() async {
        guard !isRunning else { return }

        isRunning = true
        testResults.removeAll()
        currentTest = "Initializing..."

        // Custom implementation to capture results
        let grpcTest = GRPCTest()
        let tests: [(String, () async throws -> Void)] = [
            ("Proper Client Configuration", grpcTest.testWithProperClientConfiguration),
            ("Manual Client Creation", grpcTest.testWithManualClientCreation),
            ("With Interceptors", grpcTest.testWithInterceptors)
        ]

        for (testName, test) in tests {
            await MainActor.run {
                currentTest = testName
            }

            let startTime = Date()

            do {
                try await test()
                let duration = Date().timeIntervalSince(startTime)

                await MainActor.run {
                    testResults.append(TestResult(
                        name: testName,
                        success: true,
                        message: "Test completed successfully",
                        duration: duration,
                        timestamp: Date()
                    ))
                }
            } catch {
                let duration = Date().timeIntervalSince(startTime)

                await MainActor.run {
                    testResults.append(TestResult(
                        name: testName,
                        success: false,
                        message: error.localizedDescription,
                        duration: duration,
                        timestamp: Date()
                    ))
                }
            }

            // Wait between tests
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        await MainActor.run {
            isRunning = false
            currentTest = ""
        }
    }

    private func runSingleTest(_ testType: TestType) async {
        guard !isRunning else { return }

        isRunning = true
        currentTest = testType.rawValue

        let testRunner = TestRunner()
        let startTime = Date()

        await testRunner.runSingleTest(testType)
        let duration = Date().timeIntervalSince(startTime)

        await MainActor.run {
            testResults.append(TestResult(
                name: testType.rawValue,
                success: true,
                message: "Test completed successfully",
                duration: duration,
                timestamp: Date()
            ))
        }

        await MainActor.run {
            isRunning = false
            currentTest = ""
        }
    }
}

struct TestResult: Identifiable {
    let id = UUID()
    let name: String
    let success: Bool
    let message: String
    let duration: TimeInterval
    let timestamp: Date
}

struct TestResultRow: View {
    let result: TestResult
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(result.success ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.headline)

                Text(result.message)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Duration: \(String(format: "%.2f", result.duration))s")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(DateFormatter.testTimestamp.string(from: result.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.secondary.opacity(0.05) : Color(NSColor.controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

extension DateFormatter {
    static let testTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

#Preview {
    GRPCTestView(selectedResult: .constant(nil))
}