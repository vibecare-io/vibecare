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
