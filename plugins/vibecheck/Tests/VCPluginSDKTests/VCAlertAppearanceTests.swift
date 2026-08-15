import Testing
import Foundation
import VCPluginSDK

// `VCAlertAppearance` exists to make the client's alert-appearance schema a
// typed, documented thing rather than JSON every plugin re-derives by reading
// the client's source. These tests pin the three properties that makes true:
// absent means ABSENT on the wire, the key names and enum spellings are the
// client's, and attaching one to a `VCAlert` never requires touching JSON.

// MARK: - Absence

// The load-bearing rule of the schema. The client fills an omitted field from
// its own default, so encoding an unset property as `null` — or worse, as `0`
// or `""` — would silently assert "no icon, zero width, never dismiss" on
// every alert that merely had no opinion. An `encodeIfPresent` that regressed
// to `encode` compiles fine and fails only here.
@Test func anEmptyAppearanceEncodesToAnEmptyObject() throws {
    let encoded = try #require(VCAlertAppearance().encoded())
    #expect(encoded == "{}")
}

@Test func unsetPropertiesAreOmittedRatherThanNulled() throws {
    // Exactly one field set, so anything else appearing is the bug.
    let encoded = try #require(VCAlertAppearance(width: 450).encoded())
    #expect(encoded == #"{"width":450}"#)
    #expect(!encoded.contains("null"))
}

@Test func settingAFieldToItsZeroValueIsStillDistinctFromLeavingItUnset() throws {
    // `0` and `false` are real, sendable values; the schema says nothing
    // about them being placeholders. A future "skip empty values"
    // optimisation would break exactly this.
    let encoded = try #require(
        VCAlertAppearance(width: 0, moveable: false, autoDismissAfter: 0).encoded()
    )
    #expect(encoded == #"{"autoDismissAfter":0,"moveable":false,"width":0}"#)
}

// MARK: - The wire shape

// The full set of keys, spelled the way the client spells them. This is the
// contract a future plugin author reads the SDK instead of the client for; if
// a property is ever renamed without updating `CodingKeys`, this is the test
// that says so.
@Test func everyPropertyProducesExactlyTheDocumentedKey() throws {
    let all = VCAlertAppearance(
        bundledIconId: "bell",
        svgPath: "icons/nail-biting.svg",
        svgWidth: 220,
        svgHeight: 150,
        position: .bottomRight,
        width: 450,
        height: 220,
        moveable: true,
        autoDismissAfter: 20,
        screenBlurEnabled: true,
        screenBlurIntensity: .light,
        title: "Hands off",
        message: "take a breath"
    )
    let encoded = try #require(all.encoded())

    // Sorted-key order, so this literal is also the determinism assertion:
    // an unsorted encoder would shuffle it between runs.
    #expect(encoded == #"{"autoDismissAfter":20,"bundledIconId":"bell","height":220,"message":"take a breath","moveable":true,"position":"bottomRight","screenBlurEnabled":true,"screenBlurIntensity":"light","svgHeight":150,"svgPath":"icons\/nail-biting.svg","svgWidth":220,"title":"Hands off","width":450}"#)
}

@Test func encodingIsDeterministicAcrossCalls() throws {
    let a = VCAlertAppearance(position: .topLeft, width: 300, height: 120,
                              moveable: false, screenBlurEnabled: true,
                              screenBlurIntensity: .heavy)
    let first = try #require(a.encoded())
    for _ in 0..<20 {
        #expect(a.encoded() == first)
    }
}

// MARK: - Enum vocabularies

// The whole point of the enums is that a typo cannot reach the wire. That
// only holds if the raw values are the strings the client actually matches
// on — a case renamed for Swift style ("topRight" -> "upperRight") would
// compile everywhere and quietly stop positioning alerts.
@Test func positionRawValuesAreTheClientsSpellings() {
    #expect(VCAlertAppearance.Position.center.rawValue == "center")
    #expect(VCAlertAppearance.Position.topLeft.rawValue == "topLeft")
    #expect(VCAlertAppearance.Position.topRight.rawValue == "topRight")
    #expect(VCAlertAppearance.Position.bottomLeft.rawValue == "bottomLeft")
    #expect(VCAlertAppearance.Position.bottomRight.rawValue == "bottomRight")
    // The complete valid set, pinned: the client rejects anything else, so a
    // sixth case here would be a field the renderer silently drops.
    #expect(VCAlertAppearance.Position.allCases.map(\.rawValue)
            == ["center", "topLeft", "topRight", "bottomLeft", "bottomRight"])
}

@Test func blurIntensityRawValuesAreTheClientsSpellings() {
    #expect(VCAlertAppearance.BlurIntensity.light.rawValue == "light")
    #expect(VCAlertAppearance.BlurIntensity.medium.rawValue == "medium")
    #expect(VCAlertAppearance.BlurIntensity.heavy.rawValue == "heavy")
    #expect(VCAlertAppearance.BlurIntensity.allCases.map(\.rawValue)
            == ["light", "medium", "heavy"])
}

@Test func enumsEncodeAsBareStringsNotWrappedObjects() throws {
    let encoded = try #require(
        VCAlertAppearance(position: .center, screenBlurIntensity: .medium).encoded()
    )
    #expect(encoded == #"{"position":"center","screenBlurIntensity":"medium"}"#)
}

// MARK: - Attaching to an alert

@Test func theTypedInitializerEncodesIntoTheRawAppearanceField() throws {
    let alert = VCAlert(
        title: "Hands off", body: "3rd nudge today", level: "warn",
        actions: [VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10")],
        appearance: VCAlertAppearance(position: .center, width: 450)
    )
    #expect(alert.appearance == #"{"position":"center","width":450}"#)
    // Styling must not cost the alert anything else — the action buttons in
    // particular are the user's way out of whatever the plugin is doing.
    #expect(alert.title == "Hands off")
    #expect(alert.level == "warn")
    #expect(alert.actions.map(\.url) == ["api/snooze?minutes=10"])
}

// The raw path is still a supported way to send an appearance; plugins
// written before this type existed must keep working byte-for-byte.
@Test func theRawStringPathIsUnchanged() {
    let blob = #"{"width":450,"title":"say \"hi\" 💛"}"#
    let alert = VCAlert(title: "T", body: "B", appearance: blob)
    #expect(alert.appearance == blob)

    #expect(VCAlert(title: "T", body: "B").appearance == nil)
}

// Precedence: one storage, last write wins. If the typed appearance were ever
// stored separately, these two would disagree about what actually goes on the
// wire — which is the failure this design exists to make impossible.
@Test func theLastAppearanceWrittenIsTheOneSent() {
    var alert = VCAlert(title: "T", body: "B", appearance: #"{"width":1}"#)
    alert.setAppearance(VCAlertAppearance(width: 2))
    #expect(alert.appearance == #"{"width":2}"#)

    alert.appearance = #"{"width":3}"#
    #expect(alert.appearance == #"{"width":3}"#)

    #expect(alert.styled(VCAlertAppearance(width: 4)).appearance == #"{"width":4}"#)
    // `styled` returns a copy; the original is untouched.
    #expect(alert.appearance == #"{"width":3}"#)
}

// MARK: - Round trip

// Decoding is not on the plugin's hot path, but the type is `Codable` and a
// plugin that persists a user-edited appearance will read it back. Absence
// must survive the round trip as absence.
@Test func appearanceRoundTripsThroughJSON() throws {
    let original = VCAlertAppearance(
        svgPath: "icons/nose-picking.svg", svgWidth: 220, svgHeight: 150,
        position: .center, width: 450, height: 220, moveable: true,
        autoDismissAfter: 20, screenBlurEnabled: true, screenBlurIntensity: .light
    )
    let encoded = try #require(original.encoded())
    let decoded = try JSONDecoder().decode(VCAlertAppearance.self, from: Data(encoded.utf8))
    #expect(decoded == original)
    #expect(decoded.bundledIconId == nil)
    #expect(decoded.title == nil)
}
