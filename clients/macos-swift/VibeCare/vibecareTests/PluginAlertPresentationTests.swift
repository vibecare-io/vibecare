import Testing
import Foundation
import CoreGraphics
// Two build systems, two module names for the app — see the long comment in
// PluginRosterTests.swift. Do not "simplify" this to one import.
#if SWIFT_PACKAGE
@testable import VibeCare
#else
@testable import vibecare
#endif

// Ruling U2: a plugin alert with an appearance renders through a
// client-owned SwiftUI view — full-size illustration, title, message, action
// buttons — instead of either of VibeNotify's built-in renderers, neither of
// which can draw an illustration AND buttons.
//
// The window geometry that view is shown in is derived here, as a value, so
// it can be asserted without a screen. Everything below would otherwise only
// be checkable by looking at a notification.

private func preferences(_ blob: String) throws -> NotificationPreferences {
    let alert = PluginAlert(plugin: "p", title: "T", body: "B", level: "warn", appearance: blob)
    return try #require(alert.appearancePreferences)
}

/// The uncustomized vibecheck blob — the "old and nice" geometry.
private let defaultBlob = #"""
{"autoDismissAfter":20,"height":220,"moveable":true,"position":"center","screenBlurEnabled":true,"screenBlurIntensity":"light","svgHeight":150,"svgPath":"icons\/nose-picking.svg","svgWidth":220,"width":450}
"""#

@Test func presentationReproducesTheOldDesignsGeometry() throws {
    let p = PluginAlertPresentation(preferences: try preferences(defaultBlob))

    #expect(p.position == .center)
    #expect(p.width == 450)
    #expect(p.minHeight == 220)
    // The illustration at FULL size — this is the whole point of U2. A
    // regression to VibeNotify's standard renderer would pin it at 48x48.
    #expect(p.iconSize == CGSize(width: 220, height: 150))
    #expect(p.blurIntensity == .light)
    #expect(p.autoDismissAfter == 20)
    #expect(p.moveable)
}

@Test func presentationHonoursACustomizedAppearance() throws {
    let blob = #"""
    {"autoDismissAfter":42,"height":400,"moveable":false,"position":"bottomRight","screenBlurEnabled":true,"screenBlurIntensity":"heavy","svgHeight":200,"svgWidth":300,"svgPath":"icons\/x.svg","width":600}
    """#
    let p = PluginAlertPresentation(preferences: try preferences(blob))

    #expect(p.position == .bottomRight)
    #expect(p.width == 600)
    #expect(p.minHeight == 400)
    #expect(p.iconSize == CGSize(width: 300, height: 200))
    #expect(p.blurIntensity == .heavy)
    #expect(p.autoDismissAfter == 42)
    #expect(p.moveable == false)
}

// A plugin that sends only some of the vocabulary still gets the old
// design's proportions for the rest, rather than a zero-sized icon or an
// alert that never dismisses.
@Test func presentationFillsOmittedFieldsWithTheOldDesignsValues() throws {
    let p = PluginAlertPresentation(preferences: try preferences(#"{"position":"topLeft"}"#))

    #expect(p.position == .topLeft)
    #expect(p.width == 450)
    #expect(p.minHeight == 220)
    #expect(p.iconSize == CGSize(width: 220, height: 150))
    #expect(p.autoDismissAfter == 20)
}

// `screenBlurEnabled:false` must produce NO blur, not a light one. The
// intensity field still carries a value when blur is off — a mapping that
// read it unconditionally would blur every alert, including from plugins
// that asked not to.
@Test func blurIsAbsentWhenTheAppearanceDisablesIt() throws {
    let blob = #"{"screenBlurEnabled":false,"screenBlurIntensity":"heavy","width":450}"#
    let p = PluginAlertPresentation(preferences: try preferences(blob))
    #expect(p.blurIntensity == nil)
}

// MARK: - Task timer

// `NotificationPreferences.taskTimerSeconds`/`taskTimerUnitLabel`/
// `taskTimerCompletionLabel` are what `VibeNotifyConfig.showNotification`
// reads to build VibeNotify's `TaskTimer` (the countdown ring) — sourced
// from an action's `task_timer_seconds` etc. parameters via
// `ScheduleActionCard`/`NotificationManager`'s deserializers. `nil` (the
// default) means no task timer at all, which is what keeps every action
// that predates this field rendering exactly as it did before. Exercised
// here at the model level — construction, `copy()`, `Equatable`/`Hashable`
// — since those are the surfaces every caller that builds or compares a
// `NotificationPreferences` actually goes through.
@Test func taskTimerFieldsDefaultToNil() {
    let p = NotificationPreferences.default
    #expect(p.taskTimerSeconds == nil)
    #expect(p.taskTimerUnitLabel == nil)
    #expect(p.taskTimerCompletionLabel == nil)
}

@Test func taskTimerFieldsSurviveCopy() {
    let p = NotificationPreferences(
        taskTimerSeconds: 20,
        taskTimerUnitLabel: "seconds",
        taskTimerCompletionLabel: "Break complete"
    )
    let copy = p.copy()

    #expect(copy.taskTimerSeconds == 20)
    #expect(copy.taskTimerUnitLabel == "seconds")
    #expect(copy.taskTimerCompletionLabel == "Break complete")
    #expect(copy !== p)
    #expect(copy == p)
}

@Test func taskTimerSecondsParticipatesInEquality() {
    let withTimer = NotificationPreferences(taskTimerSeconds: 20)
    let withoutTimer = NotificationPreferences(taskTimerSeconds: nil)
    #expect(withTimer != withoutTimer)
}

// MARK: - Routing

// An alert with no appearance is untouched by any of this.
@Test func routeIsPlainWithoutAnAppearance() {
    #expect(PluginAlertPresentation.route(preferences: nil, iconLoaded: false) == .plain)
    #expect(PluginAlertPresentation.route(preferences: nil, iconLoaded: true) == .plain)
}

// Ruling U2, verbatim: "If the icon fails to load, fall back to the standard
// path rather than showing an empty box — a missing illustration must not
// cost the user the Turn off button." The standard path is a banner, and a
// banner still draws buttons.
@Test func routeIsPlainWhenARequestedIllustrationFailedToLoad() throws {
    let prefs = try preferences(defaultBlob)
    #expect(prefs.svgPath != nil)
    #expect(PluginAlertPresentation.route(preferences: prefs, iconLoaded: false) == .plain)
}

@Test func routeIsRichOnceTheIllustrationLoaded() throws {
    let prefs = try preferences(defaultBlob)
    #expect(PluginAlertPresentation.route(preferences: prefs, iconLoaded: true) == .rich)
}

// An appearance that never asked for an illustration is NOT a failure, and
// must still be honoured — position, size and blur are styling in their own
// right. Collapsing this into the failure case above would silently ignore
// the request of any plugin that styles its alerts without an icon.
@Test func routeIsRichWhenNoIllustrationWasRequested() throws {
    let prefs = try preferences(#"{"position":"center","width":500,"screenBlurEnabled":true}"#)
    #expect(prefs.svgPath == nil)
    #expect(PluginAlertPresentation.route(preferences: prefs, iconLoaded: false) == .rich)
}
