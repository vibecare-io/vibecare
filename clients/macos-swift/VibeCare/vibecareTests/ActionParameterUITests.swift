import Testing
@testable import vibecare

@Test func systemCommandExposesCommandDropdownVocabulary() {
    let byName = Dictionary(uniqueKeysWithValues:
        ActionType.systemCommand.requiredParameters.map { ($0.name, $0) })
    #expect(byName["command"]?.allowedValues == ["lock", "sleep"])
    #expect(byName["command"]?.defaultValue == "sleep")
    #expect(byName["command"]?.required == true)
    #expect(byName["countdown_seconds"]?.defaultValue == "30")
    #expect(byName["cancelable"]?.defaultValue == "true")
    #expect(byName["message"]?.required == false)
    #expect(byName["message"]?.defaultValue == nil)
}

@Test func displayLabelHumanizesRawValues() {
    #expect(ActionParameter.displayLabel(for: "lock") == "Lock")
    #expect(ActionParameter.displayLabel(for: "sleep") == "Sleep")
    #expect(ActionParameter.displayLabel(for: "display_sleep") == "Display Sleep")
}

@Test func seedingFillsMissingSystemCommandDefaults() {
    let seeded = ActionType.systemCommand.seedingDefaults(into: [:])
    #expect(seeded["command"] == "sleep")
    #expect(seeded["countdown_seconds"] == "30")
    #expect(seeded["cancelable"] == "true")
    #expect(seeded["message"] == nil)
}

@Test func seedingPreservesExistingValues() {
    let seeded = ActionType.systemCommand.seedingDefaults(
        into: ["command": "lock", "countdown_seconds": "10"])
    #expect(seeded["command"] == "lock")
    #expect(seeded["countdown_seconds"] == "10")
    #expect(seeded["cancelable"] == "true")   // still filled from defaults
}
