import Testing
import Foundation
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

// --- Failure reporting ----------------------------------------------------
//
// The message shown when no backend answered used to always name
// ~/.vibecare/logs/server.log. That is right only when the server ran and
// failed. When REGISTRATION failed the server never started, so the file does
// not exist and naming it sends the reader hunting for evidence nobody wrote.

@Test func failureMessageNamesTheLogWhenRegistrationWasFine() {
    #expect(BackendManager.failureMessage(registrationFailure: nil)
            .contains("~/.vibecare/logs/server.log"))
}

@Test func failureMessageReportsTheRegistrationReasonInstead() {
    let msg = BackendManager.failureMessage(
        registrationFailure: "Could not register the VibeCare backend login item (status: requiresApproval).")
    #expect(msg.contains("requiresApproval"))
    // Must NOT send the user to a file that this failure never creates.
    #expect(!msg.contains("server.log"))
}

// --- Status rendering -----------------------------------------------------
//
// A status name alone is not actionable. requiresApproval in particular is
// invisible from outside the app: nothing hints that a switch in System
// Settings is what stands between the user and a working backend.

@Test func adviceForRequiresApprovalPointsAtLoginItems() {
    let advice = BackendRegistrationError.advice(for: "requiresApproval")
    #expect(advice.contains("Login Items"))
}

@Test func adviceForNotFoundBlamesTheBuild() {
    #expect(BackendRegistrationError.advice(for: "notFound").contains("io.vibecare.server.plist"))
}

@Test func registrationErrorDescriptionCarriesStatusAndAdvice() {
    let err = BackendRegistrationError(status: "requiresApproval", underlying: nil)
    let desc = err.errorDescription ?? ""
    #expect(desc.contains("requiresApproval"))
    #expect(desc.contains("Login Items"))
}

@Test func registrationErrorIncludesWhatMacOSSaid() {
    struct Boom: LocalizedError { var errorDescription: String? { "Operation not permitted" } }
    let err = BackendRegistrationError(status: "notRegistered", underlying: Boom())
    #expect((err.errorDescription ?? "").contains("Operation not permitted"))
}
