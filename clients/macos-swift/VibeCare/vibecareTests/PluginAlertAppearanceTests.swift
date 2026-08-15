import Testing
import Foundation
// Two build systems, two module names for the app — see the long comment in
// PluginRosterTests.swift. Do not "simplify" this to one import.
#if SWIFT_PACKAGE
@testable import VibeCare
import VCStubs
#else
@testable import vibecare
#endif

// Ruling U1: a plugin alert can carry its own appearance, so a plugin ships
// a richly-styled alert with no client release and no per-plugin code in the
// shell. The shell's side of that bargain is exactly what these tests pin:
// it decodes a shape it already owns (`NotificationPreferences`) and quietly
// keeps its default rendering for anything else.

/// The exact bytes the vibecheck plugin puts on the wire for an
/// uncustomized nose-picking alert. The plugin pins this same literal in
/// `plugins/vibecheck/Tests/VibeCheckKitTests/HostSinkTests.swift`
/// (`theEncodedAppearanceHasTheShapeTheClientDecodes`). Neither side can
/// import the other's type, so this pair of literals IS the cross-language
/// contract — rename or retype a field on either side and exactly one of
/// the two tests goes red. Without them, a drift shows up only as the user
/// silently getting a plain banner again, with every test still green.
private let wireBlob = #"""
{"autoDismissAfter":20,"height":220,"moveable":true,"position":"center","screenBlurEnabled":true,"screenBlurIntensity":"light","svgHeight":150,"svgPath":"icons\/nose-picking.svg","svgWidth":220,"width":450}
"""#

@Test func appearanceBlobDecodesIntoNotificationPreferences() throws {
    let alert = PluginAlert(plugin: "vibecheck", title: "Nose-picking",
                            body: "Ease off — 6th nudge today", level: "warn",
                            appearance: wireBlob)

    let prefs = try #require(alert.appearancePreferences)
    // Each of these drives a visible property of the rendered alert, and
    // each would be silently lost by a decode that "succeeded" against a
    // partially-matching schema.
    #expect(prefs.position == .center)
    #expect(prefs.width == 450)
    #expect(prefs.height == 220)
    #expect(prefs.screenBlurEnabled)
    #expect(prefs.screenBlurIntensity == .light)
    #expect(prefs.autoDismissAfter == 20)
    #expect(prefs.moveable)
    #expect(prefs.svgPath == "icons/nose-picking.svg")
    #expect(prefs.svgSize == CGSize(width: 220, height: 150))
}

// The decoded preferences are appearance ONLY, even when the blob carries
// wording. The sender already applied its own wording to the alert, plus
// whatever it computed at fire time — the nudge count here, which the stored
// preference cannot contain. A renderer that preferred `prefs.title` /
// `prefs.message` would drop the count, and for an alert whose sender never
// stored wording it would show a blank notification.
@Test func appearanceNeverSubstitutesForTheAlertsOwnWording() throws {
    let blob = #"{"message":"You've got this","position":"topRight","title":"Hands down!","width":300}"#
    let alert = PluginAlert(plugin: "vibecheck", title: "Hands down!",
                            body: "You've got this — 5th nudge today", level: "warn",
                            appearance: blob)

    let prefs = try #require(alert.appearancePreferences)
    // Styling came through...
    #expect(prefs.position == .topRight)
    #expect(prefs.width == 300)
    // ...but the wording did not, so nothing downstream can prefer it.
    #expect(prefs.title == nil)
    #expect(prefs.message == nil)
    #expect(alert.body == "You've got this — 5th nudge today")
}

// One malformed value must not cost the whole appearance: a partially
// understood style is closer to what the plugin asked for than a plain
// banner. `width` is a string here and `position` is a value this client has
// never heard of; both fall back, everything else survives.
@Test func oneBadFieldDoesNotDiscardTheRestOfTheAppearance() throws {
    let blob = #"{"width":"wide","position":"nowhere","height":300,"screenBlurEnabled":true}"#
    let alert = PluginAlert(plugin: "other", title: "T", body: "B", level: "info", appearance: blob)

    let prefs = try #require(alert.appearancePreferences)
    #expect(prefs.height == 300)
    #expect(prefs.screenBlurEnabled)
    #expect(prefs.width == NotificationPreferences.default.width)
    #expect(prefs.position == NotificationPreferences.default.position)
}

// Regression guard for the trap this schema exists to avoid.
// `NotificationPreferences` is `@Observable`, so its synthesized Codable
// emits underscore-prefixed keys and an observation registrar — a shape no
// other process would ever write. If someone "simplifies"
// `appearancePreferences` to decode `NotificationPreferences` directly, the
// wire blob above stops decoding and this shows why.
@Test func theObservableTypesOwnEncodingIsNotTheWireSchema() throws {
    let encoder = JSONEncoder()
    let native = String(decoding: try encoder.encode(NotificationPreferences.default), as: UTF8.self)
    #expect(native.contains("_$observationRegistrar"))
    #expect(!native.contains("\"width\""))
    // ...and that shape is correctly rejected as an appearance, rather than
    // half-decoding into an all-default style.
    let alert = PluginAlert(plugin: "other", title: "T", body: "B", level: "info", appearance: native)
    #expect(alert.appearancePreferences == nil)
}

// An alert with no appearance must decode to nil, not to a default-valued
// `NotificationPreferences`: nil is what routes the alert down the unchanged
// banner path, and a non-nil default would restyle every alert from every
// plugin that never asked for one.
@Test func anAlertWithoutAppearanceHasNoPreferences() {
    let alert = PluginAlert(plugin: "todo", title: "Due", body: "Buy milk", level: "info")
    #expect(alert.appearance == nil)
    #expect(alert.appearancePreferences == nil)
}

// A plugin that styles its alerts in some other schema — the whole point of
// the field being opaque — must degrade to the plain alert, not crash and
// not show a half-built one.
@Test func anUnrecognisedAppearanceIsIgnoredRatherThanFatal() {
    for blob in ["not json at all", "[]", #"{"theme":{"accent":"gold"}}"#, ""] {
        let alert = PluginAlert(plugin: "other", title: "T", body: "B", level: "info", appearance: blob)
        #expect(alert.appearancePreferences == nil, "blob \(blob) should not decode")
    }
}

// Presence, not emptiness: an explicitly-empty appearance is still an
// appearance the sender chose to send. It decodes to nothing, so the alert
// still renders plainly — but `appearance` itself must not be flattened to
// nil, or the two states become indistinguishable on the wire.
@Test func anExplicitlyEmptyAppearanceIsStillPresent() {
    let alert = PluginAlert(plugin: "other", title: "T", body: "B", level: "info", appearance: "")
    #expect(alert.appearance == "")
    #expect(alert.appearancePreferences == nil)
}

// The relative `svgPath` the plugin sends is meaningless without the
// plugin's own mount point. Resolving it is the shell's job and is generic —
// everything a plugin serves lives under `/p/<id>/` — which is what lets the
// icon load without the client knowing anything about vibecheck.
@Test func aRelativeIconPathResolvesUnderTheSendingPluginsMount() throws {
    let roster = PluginRoster(
        plugins: [PluginEntry(id: "vibecheck", name: "VibeCheck", icon: "eye",
                              path: "/p/vibecheck/", state: .up, detail: "")],
        baseURL: "http://127.0.0.1:52341",
        token: "tok"
    )
    let url = try #require(roster.url(for: "vibecheck", path: "icons/nose-picking.svg"))
    #expect(url.absoluteString == "http://127.0.0.1:52341/p/vibecheck/icons/nose-picking.svg")

    // A plugin that is no longer in the roster resolves to nil rather than a
    // malformed URL, so a dead plugin's alert loses its icon, not the alert.
    #expect(roster.url(for: "gone", path: "icons/x.svg") == nil)
}

#if SWIFT_PACKAGE
// `PluginAlert(proto:)` is the only place the wire's explicit presence
// becomes the model's `String?`, and no test built from the in-memory
// initializer can reach it. These drive the real protobuf.

@Test func protoAlertCarriesAppearanceWhenTheWireHasIt() {
    var proto = VCKAlert()
    proto.plugin = "vibecheck"
    proto.title = "Nose-picking"
    proto.body = "Ease off"
    proto.level = "warn"
    proto.appearance = wireBlob

    let alert = PluginAlert(proto: proto)
    #expect(alert.appearance == wireBlob)
    #expect(alert.appearancePreferences?.width == 450)
}

// Absence on the wire must stay absence in the model. `proto.appearance`
// reads back as "" for an unset field, so a mapping that copied it
// unconditionally would turn every plain alert into one carrying an empty
// appearance — indistinguishable from a plugin that deliberately sent one.
@Test func protoAlertWithoutAppearanceMapsToNil() {
    var proto = VCKAlert()
    proto.plugin = "todo"
    proto.title = "Due"
    #expect(proto.hasAppearance == false)

    let alert = PluginAlert(proto: proto)
    #expect(alert.appearance == nil)
    #expect(alert.appearancePreferences == nil)
}

// Actions survive alongside the appearance all the way into the model —
// the "Turn off" button is the user's way to stop a camera they want off,
// and must not be a casualty of a prettier alert.
@Test func protoAlertKeepsActionsAlongsideAppearance() {
    var snooze = VCKAlertAction()
    snooze.label = "Snooze 10 min"
    snooze.url = "api/snooze?minutes=10"
    var off = VCKAlertAction()
    off.label = "Turn off"
    off.url = "api/config/disable"

    var proto = VCKAlert()
    proto.plugin = "vibecheck"
    proto.level = "warn"
    proto.actions = [snooze, off]
    proto.appearance = wireBlob

    let alert = PluginAlert(proto: proto)
    #expect(alert.actions.map(\.label) == ["Snooze 10 min", "Turn off"])
    #expect(alert.actions.map(\.url) == ["api/snooze?minutes=10", "api/config/disable"])
    #expect(alert.appearancePreferences != nil)
}
#endif
