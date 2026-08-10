import Foundation
import SwiftUI

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

@MainActor
final class BackendManager: ObservableObject {
    static let shared = BackendManager()

    enum State: Equatable { case starting, ready, failed(String) }
    @Published var state: State = .starting
    @Published var backendVersion: String?
    @Published var backendStale = false

    private let supervisor: BackendSupervisor
    private let appVersion: String
    private let statusURL: URL
    private let versionURL: URL

    init(supervisor: BackendSupervisor = SMAppServiceSupervisor(),
         appVersion: String = Bundle.main.appVersion,
         statusURL: URL = URL(string: "http://localhost:8080/status")!,
         versionURL: URL = URL(string: "http://localhost:8080/version")!) {
        self.supervisor = supervisor
        self.appVersion = appVersion
        self.statusURL = statusURL
        self.versionURL = versionURL
    }

    /// Pure, testable: backend is stale iff it reports a version that differs
    /// from the app's own. Unknown (nil) backend version is NOT stale.
    nonisolated static func isStale(appVersion: String, backendVersion: String?) -> Bool {
        guard let b = backendVersion else { return false }
        return b != appVersion
    }

    /// Pure, testable: should the app silently restart a stale backend?
    nonisolated static func shouldAutoRestart(stale: Bool, autoReloadEnabled: Bool) -> Bool {
        stale && autoReloadEnabled
    }

    /// Persisted user preference — "Automatically restart backend after an update".
    /// Defaults to true when unset.
    var autoReloadEnabled: Bool {
        UserDefaults.standard.object(forKey: "backend.autoReload") as? Bool ?? true
    }

    func ensureRunning() async {
        state = .starting
        do { try supervisor.ensureRegistered() }
        catch { /* fall through — maybe already running via `just run` */ }
        if await waitForHealthy(timeout: 15) {
            backendVersion = await probeVersion()
            backendStale = Self.isStale(appVersion: appVersion, backendVersion: backendVersion)
            state = .ready
            if Self.shouldAutoRestart(stale: backendStale, autoReloadEnabled: autoReloadEnabled) {
                await restart()
            }
        } else {
            state = .failed("The VibeCare backend didn't start. Check ~/.vibecare/logs/server.log.")
        }
    }

    func restart() async {
        state = .starting
        try? supervisor.restart()
        if await waitForHealthy(timeout: 15) {
            backendVersion = await probeVersion()
            backendStale = Self.isStale(appVersion: appVersion, backendVersion: backendVersion)
            state = .ready
        } else {
            state = .failed("Backend failed to restart.")
        }
    }

    private func waitForHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await probeHealthy() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }
    private func probeHealthy() async -> Bool {
        var req = URLRequest(url: statusURL); req.timeoutInterval = 2
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse { return http.statusCode == 200 }
        return false
    }
    private func probeVersion() async -> String? {
        var req = URLRequest(url: versionURL); req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONDecoder().decode([String:String].self, from: data) else { return nil }
        return obj["version"]
    }
}
