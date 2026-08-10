import Foundation
import ServiceManagement

protocol BackendSupervisor {
    func ensureRegistered() throws
    func restart() throws
    func isRegistered() -> Bool
}

/// macOS conformer: a bundled user LaunchAgent managed via SMAppService.
/// (Linux/Windows conformers to follow — see the design's cross-platform note.)
struct SMAppServiceSupervisor: BackendSupervisor {
    private var agent: SMAppService { SMAppService.agent(plistName: "io.vibecare.server.plist") }
    func isRegistered() -> Bool { agent.status == .enabled }
    func ensureRegistered() throws { if agent.status != .enabled { try agent.register() } }
    func restart() throws { try? agent.unregister(); try agent.register() }
}
