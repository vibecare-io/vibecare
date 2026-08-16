import Foundation

/// One earned nudge: poor posture held for `sustained` seconds, confirmed at
/// `time`.
public struct PostureNudge: Sendable, Equatable {
    public let faults: PostureFaults
    /// The time this fired, on the same clock the caller feeds `ingest`.
    public let time: TimeInterval
    /// How long posture had been continuously poor when it fired. Always at
    /// least `dwell`, and considerably more when a cooldown held the nudge
    /// back — which is why the alert quotes this rather than `dwell`.
    public let sustained: TimeInterval

    public init(faults: PostureFaults, time: TimeInterval, sustained: TimeInterval) {
        self.faults = faults
        self.time = time
        self.sustained = sustained
    }
}

/// Turns a stream of per-frame `PostureVerdict`s into earned nudges.
///
/// Same shape as `plugins/vibecheck/Sources/VibeCheckKit/DetectionPolicy.swift`
/// — dwell to confirm, cooldown to suppress, pure and deterministic given
/// `(verdict, time)` — with one addition that vibecheck does not need.
///
/// **Why `unknownGrace` exists.** vibecheck's dwell is 0.15 s, so a single
/// frame with no hit clearing the timer costs nothing; it re-accumulates in
/// three more frames. Postures' dwell is 120 s at 2 fps, so the same rule
/// would mean one dropped frame in two hundred and forty throws away two
/// minutes of accumulated evidence — and posture keeps producing `.unknown`
/// frames for entirely ordinary reasons (a hand crosses the shoulder, the
/// chair swivels, Vision's confidence dips under the joint threshold for a
/// beat). Without a grace window the nudge would essentially never fire.
///
/// So `.unknown` does not clear the dwell immediately: it clears it only
/// after `unknownGrace` seconds of CONTINUOUS unknown, at which point the
/// honest statement is "we stopped being able to see, we cannot claim the
/// run continued". `.unknown` never fires a nudge under any circumstances.
///
/// **A gap in the stream itself is the caller's problem, not this type's.**
/// This has no wall clock and cannot tell "no frames for an hour" from "one
/// frame per hour". `PostureMonitor` resets the policy when the inter-frame
/// gap exceeds its own threshold, which is what stops a laptop waking from
/// sleep with a two-hour-old `poorSince` and nudging instantly.
public struct PosturePolicy: Sendable {
    public var dwell: TimeInterval
    public var cooldown: TimeInterval
    public var unknownGrace: TimeInterval

    /// When the current uninterrupted run of poor posture began. `nil` means
    /// no run is in progress.
    private var poorSince: TimeInterval?
    /// When the current uninterrupted run of `.unknown` began, used only to
    /// decide when it has gone on long enough to break `poorSince`.
    private var unknownSince: TimeInterval?
    private var lastFired: TimeInterval?

    public init(dwell: TimeInterval, cooldown: TimeInterval, unknownGrace: TimeInterval = 5) {
        self.dwell = dwell
        self.cooldown = cooldown
        self.unknownGrace = unknownGrace
    }

    public mutating func ingest(_ verdict: PostureVerdict, at time: TimeInterval) -> PostureNudge? {
        switch verdict {
        case .good:
            // Recovery. The run is over the instant posture is good, with no
            // grace in this direction: a user who straightens up has genuinely
            // stopped slouching, and there is nothing to be generous about.
            poorSince = nil
            unknownSince = nil
            return nil

        case .unknown:
            let start = unknownSince ?? time
            unknownSince = start
            if time - start >= unknownGrace { poorSince = nil }
            return nil

        case .poor(let faults):
            unknownSince = nil
            let start = poorSince ?? time
            poorSince = start

            let sustained = time - start
            if sustained < dwell { return nil }
            // Inside the cooldown, `poorSince` is deliberately LEFT SET. The
            // run has not ended just because we are not allowed to mention
            // it, so the moment the cooldown lapses the nudge fires
            // immediately rather than starting another full dwell — which
            // would silently stretch the real interval to
            // cooldown + dwell.
            if let last = lastFired, time - last < cooldown { return nil }

            lastFired = time
            poorSince = nil
            return PostureNudge(faults: faults, time: time, sustained: sustained)
        }
    }

    /// How long posture has been continuously poor as of `time`, for the
    /// `/api/state` readout. `nil` when no run is in progress.
    public func poorFor(at time: TimeInterval) -> TimeInterval? {
        poorSince.map { time - $0 }
    }

    public var lastNudgeTime: TimeInterval? { lastFired }

    /// Forgets the in-progress run without forgetting the last nudge.
    ///
    /// Called when the evidence stops being comparable — a config change that
    /// moves the thresholds, a gap in the frame stream, the feature being
    /// switched off. `lastFired` deliberately SURVIVES: dropping it would
    /// make "edit any setting" a way to bypass the cooldown and get nudged
    /// again immediately, which is the one thing the cooldown exists to
    /// prevent.
    public mutating func reset() {
        poorSince = nil
        unknownSince = nil
    }
}
