import Testing
import Foundation
@testable import VCPluginSDK

@Test func parsesAllThreeVariables() throws {
    let env = VCEnvironment.from([
        "VIBECARE_SOCKET": "/tmp/core.sock",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ])
    let parsed = try env.get()
    #expect(parsed.socketPath == "/tmp/core.sock")
    #expect(parsed.pluginID == "vibecheck")
    #expect(parsed.dataDir.path == "/tmp/data/vibecheck")
}

@Test func rejectsEachMissingVariable() {
    let complete = [
        "VIBECARE_SOCKET": "/tmp/core.sock",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ]
    for key in complete.keys {
        var partial = complete
        partial.removeValue(forKey: key)
        #expect(throws: VCEnvironmentError.self) {
            try VCEnvironment.from(partial).get()
        }
    }
}

@Test func rejectsEmptyStringSameAsMissing() {
    // An empty value is a misconfigured spawn, not a valid socket path.
    // vc.go:145-150 treats it identically to absent.
    var env = [
        "VIBECARE_SOCKET": "",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ]
    #expect(throws: VCEnvironmentError.self) { try VCEnvironment.from(env).get() }
    env["VIBECARE_SOCKET"] = "/tmp/core.sock"
    env["VIBECARE_PLUGIN_ID"] = ""
    #expect(throws: VCEnvironmentError.self) { try VCEnvironment.from(env).get() }
}
