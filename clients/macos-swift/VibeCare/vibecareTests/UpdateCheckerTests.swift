import Testing
@testable import vibecare

@Test func parsesTagFromReleasesLatestRedirect() {
    #expect(UpdateChecker.tag(fromLocation: "https://github.com/vibecare-io/vibecare/releases/tag/v0.8.10.26-2") == "v0.8.10.26-2")
    #expect(UpdateChecker.tag(fromLocation: "https://github.com/vibecare-io/vibecare/releases/tag/v1.0.0/") == "v1.0.0")
    #expect(UpdateChecker.tag(fromLocation: "https://github.com/vibecare-io/vibecare/releases") == nil)
    #expect(UpdateChecker.tag(fromLocation: "") == nil)
}

@Test func updateAvailableOnlyWhenLatestTagDiffers() {
    // Same version → up to date
    #expect(UpdateChecker.isUpdateAvailable(installed: "v0.8.10.26-1", latest: "v0.8.10.26-1") == false)
    // Different latest → behind
    #expect(UpdateChecker.isUpdateAvailable(installed: "v0.8.10.26-1", latest: "v0.8.11.26") == true)
    // Whitespace tolerated (still equal → up to date)
    #expect(UpdateChecker.isUpdateAvailable(installed: "v0.8.10.26-1", latest: " v0.8.10.26-1 ") == false)
    // Empty/unknown inputs are never "available"
    #expect(UpdateChecker.isUpdateAvailable(installed: "v0.8.10.26-1", latest: "") == false)
    #expect(UpdateChecker.isUpdateAvailable(installed: "unknown", latest: "") == false)
}
