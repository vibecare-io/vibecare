import SwiftUI
import Logging
import OpenTelemetryApi

@main
struct VibeCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    private let logger = Logger(label: "com.vibecare.app")

    init() {
        // Setup logging
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "com.vibecare.app")
        logger.info("VibeCare macOS app starting up")

        // Initialize OpenTelemetry
        let _ = OTELManager.shared
        logger.info("OpenTelemetry initialized and connected to Jaeger")

        // gRPC connection will be initialized when app appears

        logger.info("VibeCare app startup completed")
    }

    var body: some Scene {
        WindowGroup("VibeCare", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    // Load initial data
                    Task {
                        await appState.loadInitialData()

                        // VibeNotify requires no permission setup - ready to use!
                        logger.info("App loaded - VibeNotify ready for notifications")
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