import Testing
import Foundation
@testable import VCPluginSDK

@Test func doublesFromOneSecondAndCapsAtEight() {
    var ladder = VCReconnectLadder()
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 1)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 2)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 4)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
}

@Test func aStableSessionResetsTheLadder() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)   // now at 4
    // A session that survived the stability threshold means the previous
    // failures were unrelated; the next drop starts over at the bottom.
    #expect(ladder.sessionEnded(lastedSeconds: 60) == 1)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 2)
}

@Test func aSessionJustUnderTheThresholdDoesNotReset() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)   // 1
    #expect(ladder.sessionEnded(lastedSeconds: 59.9) == 2)
}

@Test func explicitResetReturnsToTheBottom() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)
    ladder.reset()
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 1)
}
