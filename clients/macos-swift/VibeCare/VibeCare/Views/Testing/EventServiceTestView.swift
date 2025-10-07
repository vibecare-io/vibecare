import SwiftUI

struct EventServiceTestView: View {
    @StateObject private var eventService = EventService.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Text("Event Service Test")
                .font(.title)

            Divider()

            // Connection Status
            GroupBox("Connection Status") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle()
                            .fill(eventService.isListening ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(eventService.isListening ? "Listening" : "Not Listening")
                    }

                    if let error = eventService.connectionError {
                        Text("Error: \(error.localizedDescription)")
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    if let lastEvent = eventService.lastEventReceived {
                        Text("Last event: \(lastEvent, formatter: dateFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // VibeNotify Test Notifications
            GroupBox("VibeNotify Notifications") {
                VStack(spacing: 10) {
                    Text("No permissions needed - VibeNotify ready!")
                        .font(.caption)
                        .foregroundColor(.green)

                    HStack(spacing: 8) {
                        Button("Success") {
                            notificationManager.showSuccess(message: "Operation completed!")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button("Error") {
                            notificationManager.showError(message: "Something went wrong!")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button("Warning") {
                            notificationManager.showWarning(message: "Be careful!")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button("Info") {
                            notificationManager.showInfo(message: "FYI notification")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Toast") {
                        notificationManager.showToast(message: "Quick toast notification!")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Manual Controls
            GroupBox("Manual Controls") {
                VStack(spacing: 10) {
                    if let profile = appState.currentProfile {
                        if eventService.isListening {
                            Button("Stop Listening") {
                                eventService.stopListening()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Button("Start Listening") {
                                Task {
                                    await eventService.startListening(for: profile.id)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    } else {
                        Text("No profile selected")
                            .foregroundColor(.secondary)
                    }

                    Button("Test Schedule Notification") {
                        notificationManager.showInfo(
                            title: "Test Schedule Triggered",
                            message: "This simulates a schedule notification"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()

            // Info
            Text("The EventService will automatically connect when a profile is selected and receive real-time schedule events from the server.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
        .padding()
        .frame(width: 400, height: 500)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .short
        return formatter
    }
}

#Preview {
    EventServiceTestView()
        .environmentObject(AppState.shared)
}