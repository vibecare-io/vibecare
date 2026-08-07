import Testing
@testable import vibecare

/// Every behavior must carry a non-empty icon and nudge so a detection
/// notification is never blank.
@Test func everyBehaviorHasNonEmptyPresentation() {
    for b in BFRBBehavior.allCases {
        #expect(!b.alertIcon.isEmpty)
        #expect(!b.nudge.isEmpty)
    }
}

@Test func behaviorIconsAreExpectedSFSymbols() {
    #expect(BFRBBehavior.nailBiting.alertIcon == "hand.raised.fill")
    #expect(BFRBBehavior.nosePicking.alertIcon == "nose.fill")
    #expect(BFRBBehavior.hairPulling.alertIcon == "comb.fill")
}

/// English ordinal suffixes, including the 11-13 exception that overrides the
/// usual 1/2/3 -> st/nd/rd rule.
@Test func ordinalSuffixesFollowEnglishRules() {
    #expect(VibeNotifyConfig.ordinal(1) == "1st")
    #expect(VibeNotifyConfig.ordinal(2) == "2nd")
    #expect(VibeNotifyConfig.ordinal(3) == "3rd")
    #expect(VibeNotifyConfig.ordinal(4) == "4th")
    #expect(VibeNotifyConfig.ordinal(11) == "11th")
    #expect(VibeNotifyConfig.ordinal(12) == "12th")
    #expect(VibeNotifyConfig.ordinal(13) == "13th")
    #expect(VibeNotifyConfig.ordinal(21) == "21st")
    #expect(VibeNotifyConfig.ordinal(22) == "22nd")
    #expect(VibeNotifyConfig.ordinal(23) == "23rd")
    #expect(VibeNotifyConfig.ordinal(101) == "101st")
    #expect(VibeNotifyConfig.ordinal(111) == "111th")
    #expect(VibeNotifyConfig.ordinal(113) == "113th")
}
