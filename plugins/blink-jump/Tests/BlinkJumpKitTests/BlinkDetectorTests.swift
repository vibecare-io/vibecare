import Foundation
import Testing
@testable import BlinkJumpKit

// The judgement half of the design's §2 rule: vision hands over `ear_l` and
// `ear_r` as measurements, and everything below decides what counts as a
// blink. Every test here owns its own clock, because the interesting
// behaviour is entirely about sequences over time.

/// Drives a detector through `(time, earL, earR)` triples and returns every
/// blink it scored, so a test reads as the shape of the eye trace rather than
/// as a wall of `ingest` calls.
private func run(
    _ detector: inout BlinkDetector,
    _ samples: [(t: TimeInterval, l: Double?, r: Double?)]
) -> [Blink] {
    var blinks: [Blink] = []
    for sample in samples {
        if let blink = detector.ingest(earL: sample.l, earR: sample.r, at: sample.t) {
            blinks.append(blink)
        }
    }
    return blinks
}

/// A steady trace at `fps`, with `ear` in both eyes.
private func hold(from t: TimeInterval, for duration: TimeInterval, ear: Double, fps: Double = 30)
    -> [(t: TimeInterval, l: Double?, r: Double?)] {
    let step = 1 / fps
    var samples: [(t: TimeInterval, l: Double?, r: Double?)] = []
    var now = t
    while now < t + duration {
        samples.append((now, ear, ear))
        now += step
    }
    return samples
}

@Test func singleBlinkScoresExactlyOnce() {
    var detector = BlinkDetector()
    let blinks = run(&detector, [
        (0.000, 0.30, 0.30),
        (0.033, 0.30, 0.30),
        (0.066, 0.15, 0.15),   // below close (0.20) — closure starts
        (0.100, 0.10, 0.10),
        (0.133, 0.14, 0.14),
        (0.166, 0.30, 0.30),   // back above open (0.25) — scores here
        (0.200, 0.31, 0.31),
    ])

    #expect(blinks.count == 1)
    #expect(blinks.first?.index == 1)
    #expect(abs((blinks.first?.closure ?? 0) - 0.100) < 0.001)
    #expect(detector.phase == .open)
    #expect(detector.blinkCount == 1)
}

@Test func slowBlinkWobblingInsideTheBandIsOneBlinkNotTwo() {
    var detector = BlinkDetector()
    // The EAR dips, recovers into the hysteresis band (0.20…0.25), dips again
    // and only then fully reopens. With a single threshold this is two blinks
    // and two jumps; the band is what makes it one.
    let blinks = run(&detector, [
        (0.00, 0.30, 0.30),
        (0.05, 0.18, 0.18),
        (0.10, 0.22, 0.22),   // in the band — still shut
        (0.15, 0.17, 0.17),
        (0.20, 0.23, 0.23),   // in the band — still shut
        (0.25, 0.16, 0.16),
        (0.35, 0.31, 0.31),   // fully open
    ])

    #expect(blinks.count == 1)
    #expect(abs((blinks.first?.closure ?? 0) - 0.30) < 0.001)
}

@Test func sustainedClosureNeverScores() {
    var detector = BlinkDetector()
    var samples = hold(from: 0, for: 0.2, ear: 0.30)
    // Eyes shut for four seconds: resting, or reading the keyboard.
    samples += hold(from: 0.2, for: 4.0, ear: 0.08)
    let duringClosure = run(&detector, samples)
    #expect(duringClosure.isEmpty)
    #expect(detector.phase == .held, "a closure past maxClosure must leave `closed`")

    // And nothing on the way back out either — looking up is not a jump.
    let onReopen = run(&detector, hold(from: 4.2, for: 0.3, ear: 0.32))
    #expect(onReopen.isEmpty)
    #expect(detector.phase == .open)
    #expect(detector.blinkCount == 0)
}

@Test func absentSignalPausesAndIsNotAClosedEye() {
    var detector = BlinkDetector()
    // Both fields absent is what arrives whenever the face model is not
    // running. Reading it as 0.0 would be a permanently shut eye.
    let blinks = run(&detector, [
        (0.0, 0.30, 0.30),
        (0.1, nil, nil),
        (0.2, nil, nil),
        (0.3, nil, nil),
    ])

    #expect(blinks.isEmpty)
    #expect(detector.phase == .absent)
    #expect(detector.reading == nil)
    #expect(detector.isTracking == false)
}

@Test func aClosureStraddlingADropoutIsDiscarded() {
    var detector = BlinkDetector()
    // Shut, then tracking is lost, then tracking returns with the eye open.
    // Nothing measured the gap — the eye could have been shut for a minute —
    // so scoring the far edge would be inventing a blink.
    let blinks = run(&detector, [
        (0.0, 0.30, 0.30),
        (0.1, 0.10, 0.10),   // closure starts
        (0.2, nil, nil),     // signal lost mid-closure
        (0.3, 0.30, 0.30),   // back, eyes open
    ])

    #expect(blinks.isEmpty)
    #expect(detector.blinkCount == 0)
    #expect(detector.phase == .open)
}

@Test func reacquiringWithEyesAlreadyShutDoesNotHandOutAFreeJump() {
    var detector = BlinkDetector()
    let blinks = run(&detector, [
        (0.0, nil, nil),      // nothing measured yet
        (0.1, 0.09, 0.09),    // first measurement is already below threshold
        (0.2, 0.09, 0.09),
        (0.3, 0.32, 0.32),    // opens
    ])

    #expect(blinks.isEmpty)
    #expect(detector.blinkCount == 0)
}

@Test func noiseAroundTheThresholdNeverScoresWithoutAFullReopen() {
    var detector = BlinkDetector()
    // Chatter that crosses `close` (0.20) repeatedly but never reaches `open`
    // (0.25). Against a single threshold this is six blinks.
    var samples: [(t: TimeInterval, l: Double?, r: Double?)] = [(0.0, 0.30, 0.30)]
    var t = 0.05
    for _ in 0..<6 {
        samples.append((t, 0.19, 0.19))
        samples.append((t + 0.03, 0.21, 0.21))
        t += 0.06
    }
    let blinks = run(&detector, samples)

    #expect(blinks.isEmpty)
    #expect(detector.phase == .closed)
}

@Test func aClosureShorterThanMinClosureIsNoise() {
    var detector = BlinkDetector()
    let blinks = run(&detector, [
        (0.00, 0.30, 0.30),
        (0.02, 0.18, 0.18),   // one stray sample below threshold
        (0.04, 0.30, 0.30),   // 20 ms — under the 40 ms floor
    ])

    #expect(blinks.isEmpty)
}

@Test func refractoryWindowSuppressesAnImmediateSecondScore() {
    var detector = BlinkDetector()
    let blinks = run(&detector, [
        (0.00, 0.30, 0.30),
        (0.05, 0.10, 0.10),
        (0.11, 0.30, 0.30),   // blink #1, 60 ms closure
        (0.13, 0.10, 0.10),
        (0.18, 0.30, 0.30),   // 70 ms after #1 — inside the 120 ms refractory
    ])

    #expect(blinks.count == 1)
    #expect(detector.blinkCount == 1)
}

@Test func oneMeasurableEyeIsEnoughToPlay() {
    var detector = BlinkDetector()
    // A bad camera angle can leave one eye unresolvable. The other one still
    // blinks, and the fused reading is just that eye.
    let blinks = run(&detector, [
        (0.00, 0.30, nil),
        (0.05, 0.12, nil),
        (0.12, 0.30, nil),
    ])

    #expect(blinks.count == 1)
    #expect(detector.reading == 0.30)
}

@Test func tickDeclaresAbsenceWhenTheProviderGoesQuiet() {
    var detector = BlinkDetector()
    detector.ingest(earL: 0.30, earR: 0.30, at: 0)
    #expect(detector.phase == .open)

    // Inside the 0.8 s timeout: still tracking, nothing changed.
    #expect(detector.tick(at: 0.5) == false)
    #expect(detector.phase == .open)

    // Past it: no message at all means the provider stopped publishing, which
    // `ingest` cannot possibly notice on its own.
    #expect(detector.tick(at: 1.0) == true)
    #expect(detector.phase == .absent)
    #expect(detector.reading == nil)
    // Idempotent — a watchdog fires every 200 ms and must not re-announce.
    #expect(detector.tick(at: 1.2) == false)
}

@Test func recalibrationResetsThePhaseButKeepsTheCount() {
    var detector = BlinkDetector()
    _ = run(&detector, [
        (0.00, 0.30, 0.30),
        (0.05, 0.10, 0.10),
        (0.15, 0.30, 0.30),
    ])
    #expect(detector.blinkCount == 1)

    detector.apply(BlinkThresholds(close: 0.14))
    #expect(detector.phase == .absent, "a phase decided under the old band cannot be carried over")
    #expect(detector.blinkCount == 1, "the count is the player's, not the calibration's")
    #expect(detector.thresholds.close == 0.14)
    #expect(abs(detector.thresholds.open - 0.19) < 1e-9)
}

@Test func thresholdsClampIntoAConfigurationThatCanStillFire() {
    // A max below the min accepts no closure at all: an unplayable game with a
    // perfectly healthy-looking config file.
    let inverted = BlinkThresholds(minClosure: 0.25, maxClosure: 0.10).clamped()
    #expect(inverted.maxClosure > inverted.minClosure)

    // Zero hysteresis collapses the band and brings the chatter back.
    let flat = BlinkThresholds(hysteresis: 0).clamped()
    #expect(flat.hysteresis > 0)

    let nonsense = BlinkThresholds(close: .nan, hysteresis: .infinity).clamped()
    #expect(nonsense.close == BlinkThresholds.default.close)
    #expect(nonsense.hysteresis <= 0.20)
}
