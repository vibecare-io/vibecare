import XCTest
// This file is compiled by two different build systems with two different
// module names for the app: SwiftPM's `VibeCare` executable target (built
// by `swift test` / `just swift-test`) and the Xcode project's `vibecare`
// app target (PRODUCT_MODULE_NAME=vibecare — `vibecareTests/` is a
// file-system-synchronized group, so Xcode picks this file up too, but its
// test target links no SwiftPM package products, so `VibeCare` doesn't
// resolve there). `SWIFT_PACKAGE` is defined automatically by SwiftPM and
// only by SwiftPM, so branch on it rather than relying on case-insensitive
// APFS module matching (fragile, and not how Xcode actually resolves
// modules). Do not "simplify" this to one import — it breaks one build
// system or the other.
#if SWIFT_PACKAGE
@testable import VibeCare
#else
@testable import vibecare
#endif

final class PluginRosterTests: XCTestCase {
    private func entry(
        id: String = "todo",
        path: String = "/p/todo/",
        state: PluginState = .up,
        detail: String = ""
    ) -> PluginEntry {
        PluginEntry(id: id, name: "Todo", icon: "checklist", path: path, state: state, detail: detail)
    }

    private func roster(
        _ entries: [PluginEntry],
        baseURL: String = "http://127.0.0.1:52341",
        token: String = "abc123"
    ) -> PluginRoster {
        PluginRoster(plugins: entries, baseURL: baseURL, token: token)
    }

    // The token rides on the initial load only; core exchanges it for a
    // cookie and redirects it away.
    func testHandoffURLCarriesTheToken() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).handoffURL(for: e))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/?vc=abc123")
    }

    func testHandoffURLIsNilWithoutABaseURL() {
        let e = entry()
        XCTAssertNil(roster([e], baseURL: "").handoffURL(for: e))
    }

    // Alert actions are plugin-relative and reuse the proxy rather than
    // inventing a callback channel.
    func testActionURLIsPluginRelative() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).url(for: e, path: "snooze"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/snooze")
    }

    func testActionURLToleratesALeadingSlash() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).url(for: e, path: "/snooze"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/snooze")
    }

    // The path is stable across restarts by construction, so the shell must
    // use it verbatim rather than rebuilding it from the id.
    func testURLUsesTheServerSuppliedPath() throws {
        let e = entry(id: "todo", path: "/p/todo/")
        let url = try XCTUnwrap(roster([e]).handoffURL(for: e))
        // `url.path` (deprecated) normalizes away a trailing slash on this
        // toolchain's Foundation; `path(percentEncoded:)` is the RFC-3986
        // accessor that preserves it, which is what this assertion needs.
        XCTAssertTrue(url.path(percentEncoded: false).hasPrefix("/p/todo/"))
    }

    // The built-in dashboard row (D12) uses the same handoff shape as any
    // plugin — token rides once, exchanged for a cookie by core — just at
    // core's own reserved path instead of a plugin's.
    func testCoreStatusURLPointsAtCoreStatusWithTheToken() throws {
        let url = try XCTUnwrap(roster([entry()]).coreStatusURL())
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/_core/status?vc=abc123")
    }

    func testCoreStatusURLIsNilWithoutABaseURL() {
        XCTAssertNil(roster([entry()], baseURL: "").coreStatusURL())
    }

    // The core dashboard row must never collide with a real plugin id —
    // core's manifest id regex rejects a leading underscore for exactly
    // this reason.
    func testCoreStatusIDCannotCollideWithARealPluginID() {
        XCTAssertTrue(PluginRoster.coreStatusID.hasPrefix("_"))
    }

    func testStateParsingCoversEveryCase() {
        XCTAssertEqual(PluginState(protoState: .starting), .starting)
        XCTAssertEqual(PluginState(protoState: .up), .up)
        XCTAssertEqual(PluginState(protoState: .degraded), .degraded)
        XCTAssertEqual(PluginState(protoState: .down), .down)
        XCTAssertEqual(PluginState(protoState: .failed), .failed)
    }

    // A plugin that is up should render; one that isn't should show the
    // shell's own status rather than loading a webview onto an error page.
    func testIsViewableOnlyWhenServing() {
        XCTAssertTrue(entry(state: .up).isViewable)
        XCTAssertTrue(entry(state: .degraded).isViewable)
        XCTAssertFalse(entry(state: .starting).isViewable)
        XCTAssertFalse(entry(state: .down).isViewable)
        XCTAssertFalse(entry(state: .failed).isViewable)
    }

    // The reload token must change when a plugin transitions back to up, or
    // the user is left on a stale error page.
    func testReloadTokenChangesWithState() {
        let down = entry(state: .down)
        let up = entry(state: .up)
        XCTAssertNotEqual(down.reloadToken, up.reloadToken)
        XCTAssertEqual(up.reloadToken, entry(state: .up).reloadToken)
    }
}
