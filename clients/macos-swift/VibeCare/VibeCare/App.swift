import SwiftUI
import Logging
import UserNotifications

@main
struct VibeCareApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var notificationManager = NotificationManager.shared
    private let logger = Logger(label: "com.vibecare.app")

    init() {
        // Setup logging
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "com.vibecare.app")
        logger.info("VibeCare macOS app starting up")

        // gRPC connection will be initialized when app appears

        logger.info("VibeCare app startup completed")
    }

    var body: some Scene {
        WindowGroup("VibeCare", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(notificationManager)
                .onAppear {
                    // Load initial data and setup notifications
                    Task {
                        await appState.loadInitialData()

                        // Request notification permissions
                        let granted = await notificationManager.requestPermissions()
                        if granted {
                            logger.info("Notification permissions granted")
                        } else {
                            logger.warning("Notification permissions not granted")
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appState.handleAppBecameActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    appState.handleAppWillResignActive()
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)

        #if os(macOS)
        // Menu Bar Extra for macOS
        MenuBarExtra(
            "VibeCare",
            systemImage: appState.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
        ) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        // Settings Window
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 600, height: 400)
        .windowResizability(.contentSize)
        #endif
    }
}