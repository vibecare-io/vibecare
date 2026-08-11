import Testing
@testable import vibecare

@Test func staleWhenBackendOlderOrDifferent() {
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.26") == false)
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.25") == true)
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: "v0.8.7.26-dirty") == true)
}

@Test func notStaleWhenBackendVersionUnknown() {
    // Unknown backend version (not yet probed / offline) is not "stale" — it's just unknown.
    #expect(BackendManager.isStale(appVersion: "v0.8.7.26", backendVersion: nil) == false)
}

@Test func devClientVersionIsNeverStale() {
    // Dev builds report a non-release app version ("1.0"/"dev"); the staleness
    // check must NOT fire even though the running backend reports a real tag —
    // otherwise dev shows a false "restart the backend" banner.
    #expect(BackendManager.isStale(appVersion: "1.0", backendVersion: "v0.8.10.26-1") == false)
    #expect(BackendManager.isStale(appVersion: "dev", backendVersion: "v0.8.10.26-1") == false)
}

@Test func autoRestartsWhenStaleAndEnabled() {
    #expect(BackendManager.shouldAutoRestart(stale: true, autoReloadEnabled: true) == true)
}

@Test func doesNotAutoRestartWhenStaleButDisabled() {
    #expect(BackendManager.shouldAutoRestart(stale: true, autoReloadEnabled: false) == false)
}

@Test func doesNotAutoRestartWhenNotStale() {
    #expect(BackendManager.shouldAutoRestart(stale: false, autoReloadEnabled: true) == false)
}
