import Foundation

/// Monotonic seconds since a captured reference point.
///
/// `ContinuousClock`, never `Date`: every duration this file reasons about
/// (closure length, refractory window, signal timeout) is a *delta*, and a
/// wall clock can step backwards under NTP. A negative delta would make
/// `t - closedSince <= maxClosure` trivially true and turn a five-minute
/// resting closure into a blink.
public enum BlinkClock {
    public static func seconds(since epoch: ContinuousClock.Instant) -> TimeInterval {
        let d = ContinuousClock.now - epoch
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// The player-tunable half of blink detection.
///
/// Every one of these is a *judgement* about behaviour, which is exactly why
/// it lives here and not in the vision provider (design §2: vision publishes
/// `ear_l = 0.11`, this plugin decides "blinked"). Vision has no opinion about
/// what counts as a blink and must never be asked for one.
///
/// Persisted verbatim in `config.json` under `VIBECARE_DATA_DIR`, because eye
/// shape differs enough between people that one shipped threshold is wrong for
/// somebody — see `ConfigStore` and the UI's Calibrate button.
public struct BlinkThresholds: Codable, Sendable, Equatable {
    /// Eye counts as shut once the fused EAR drops below this.
    public var close: Double
    /// How far back *above* `close` the EAR must climb before the eye counts
    /// as open again. This is the entire anti-chatter mechanism: an EAR
    /// wobbling either side of a single threshold would open and shut several
    /// times inside one slow blink and score each one as a jump.
    public var hysteresis: Double
    /// Closures shorter than this are measurement noise, not a blink.
    public var minClosure: TimeInterval
    /// Closures longer than this are a person resting their eyes or looking
    /// down at the keyboard. They emit nothing — not on the way in (which
    /// would be a jump the moment you relax) and not on the way back out
    /// (which would be a jump the moment you look up again).
    public var maxClosure: TimeInterval
    /// Minimum spacing between two scored blinks. A real double-blink is
    /// ~150 ms apart at the very fastest; anything tighter is one blink whose
    /// EAR bounced.
    public var refractory: TimeInterval
    /// How long a gap in `vision.signals.v1` is tolerated before the detector
    /// declares itself blind. This is the *no message at all* case — the
    /// provider stopped publishing, which is categorically different from a
    /// published message carrying no EAR.
    public var signalTimeout: TimeInterval

    public init(
        close: Double = 0.20,
        hysteresis: Double = 0.05,
        minClosure: TimeInterval = 0.04,
        maxClosure: TimeInterval = 0.60,
        refractory: TimeInterval = 0.12,
        signalTimeout: TimeInterval = 0.80
    ) {
        self.close = close
        self.hysteresis = hysteresis
        self.minClosure = minClosure
        self.maxClosure = maxClosure
        self.refractory = refractory
        self.signalTimeout = signalTimeout
    }

    public static let `default` = BlinkThresholds()

    /// The upper edge of the hysteresis band — the EAR at which a shut eye is
    /// declared open again.
    public var open: Double { close + hysteresis }

    /// Clamps to ranges the UI exposes, so neither a hand-edited `config.json`
    /// nor a malformed PUT can put the detector somewhere it can never fire.
    /// `hysteresis` in particular has a hard floor: at zero the band collapses
    /// and the chatter this design exists to prevent comes straight back.
    public func clamped() -> BlinkThresholds {
        var t = self
        t.close = min(0.45, max(0.02, close.isFinite ? close : Self.default.close))
        t.hysteresis = min(0.20, max(0.01, hysteresis.isFinite ? hysteresis : Self.default.hysteresis))
        t.minClosure = min(0.30, max(0, minClosure.isFinite ? minClosure : Self.default.minClosure))
        t.maxClosure = min(3.0, max(0.10, maxClosure.isFinite ? maxClosure : Self.default.maxClosure))
        // A max below the min would accept nothing at all — silently an
        // unplayable game with a perfectly healthy-looking config file.
        t.maxClosure = max(t.maxClosure, t.minClosure + 0.05)
        t.refractory = min(1.0, max(0, refractory.isFinite ? refractory : Self.default.refractory))
        t.signalTimeout = min(5.0, max(0.2, signalTimeout.isFinite ? signalTimeout : Self.default.signalTimeout))
        return t
    }
}

/// What the detector currently believes about the eye.
///
/// `absent` is a first-class state and NOT a synonym for `closed`. The whole
/// point: `ear_l` is missing whenever the face model is not running, and a
/// consumer that reads absent as `0.0` sees a permanently shut eye — which
/// here is an infinite stream of jumps rather than a paused game.
public enum BlinkPhase: String, Codable, Sendable, Equatable {
    /// No measurement. The model is not running, or nobody is in frame.
    case absent
    case open
    /// Below `close`, still inside the window where reopening scores a blink.
    case closed
    /// Below `close` for longer than `maxClosure`. Resting, not blinking —
    /// this state exists purely so that reopening emits nothing.
    case held
}

/// One scored blink. `index` counts from 1 for the life of the process, which
/// is what the page renders as "blinks" and what makes a dropped SSE message
/// visible rather than silent.
public struct Blink: Sendable, Equatable {
    public let index: Int
    public let at: TimeInterval
    public let closure: TimeInterval
    public let ear: Double

    public init(index: Int, at: TimeInterval, closure: TimeInterval, ear: Double) {
        self.index = index
        self.at = at
        self.closure = closure
        self.ear = ear
    }
}

/// EAR in, blinks out.
///
/// A `struct` with an explicit time parameter on every entry point, rather
/// than an actor reading a clock: the interesting behaviour here is entirely
/// about *sequences over time* (slow blink, sustained closure, a dropout in
/// the middle of a closure), and those are only testable if the test owns the
/// clock.
public struct BlinkDetector: Sendable {
    public private(set) var thresholds: BlinkThresholds
    public private(set) var phase: BlinkPhase = .absent
    /// The fused EAR of the most recent measured sample; `nil` while `absent`.
    public private(set) var reading: Double?
    public private(set) var blinkCount = 0

    private var closedSince: TimeInterval?
    private var lastBlinkAt: TimeInterval?
    private var lastSampleAt: TimeInterval?

    public init(thresholds: BlinkThresholds = .default) {
        self.thresholds = thresholds.clamped()
    }

    public var isTracking: Bool { phase != .absent }

    /// Feeds one `vision.signals.v1` frame. Returns a `Blink` on the frame
    /// that completes one, and `nil` on every other frame.
    ///
    /// `earL`/`earR` are optional *individually* because presence is per field
    /// on the wire. Both absent means no measurement; one absent means one eye
    /// was resolvable and is enough to play with.
    @discardableResult
    public mutating func ingest(earL: Double?, earR: Double?, at t: TimeInterval) -> Blink? {
        guard let ear = Self.fuse(earL, earR) else {
            // Absent: pause, and DISCARD any closure in progress. A closure
            // that straddles a tracking dropout must not be scored when
            // tracking resumes — the eye could have been shut for a minute in
            // between and nothing measured it.
            phase = .absent
            reading = nil
            closedSince = nil
            lastSampleAt = t
            return nil
        }

        lastSampleAt = t
        reading = ear

        switch phase {
        case .absent:
            // Re-acquiring. Never emit on the first sample back, and if that
            // first sample is already below threshold treat it as `held`
            // rather than `closed`: someone whose eyes happened to be shut
            // when the model came up would otherwise get a free jump for
            // opening them.
            phase = ear < thresholds.close ? .held : .open

        case .open:
            if ear < thresholds.close {
                phase = .closed
                closedSince = t
            }

        case .closed:
            let since = closedSince ?? t
            if ear > thresholds.open {
                phase = .open
                closedSince = nil
                return score(closure: t - since, ear: ear, at: t)
            }
            if t - since > thresholds.maxClosure {
                // Crossed from "blinking" into "resting" without ever
                // reopening. Emitting nothing here — and nothing on the
                // eventual reopen either — is what stops a player who rests
                // their eyes from being handed a jump when they look back up.
                phase = .held
            }

        case .held:
            if ear > thresholds.open {
                phase = .open
                closedSince = nil
            }
        }
        return nil
    }

    /// Advances the timeout without a sample. Call this on a timer: *no
    /// message at all* is how a consumer learns the provider stopped
    /// publishing, and it is invisible to `ingest` by construction.
    ///
    /// Returns `true` if this call changed the phase, so a caller can push a
    /// meter update to the page exactly when something changed.
    @discardableResult
    public mutating func tick(at t: TimeInterval) -> Bool {
        guard phase != .absent else { return false }
        guard let last = lastSampleAt, t - last <= thresholds.signalTimeout else {
            phase = .absent
            reading = nil
            closedSince = nil
            return true
        }
        return false
    }

    /// Applies a recalibration. Resets to `absent` deliberately: the phase was
    /// decided against the *old* band, and carrying a `closed` recorded under
    /// a threshold the player just raised would emit a blink measured half
    /// under one rule and half under another. Counts survive — they are the
    /// player's, not the calibration's.
    public mutating func apply(_ thresholds: BlinkThresholds) {
        self.thresholds = thresholds.clamped()
        phase = .absent
        reading = nil
        closedSince = nil
    }

    private mutating func score(closure: TimeInterval, ear: Double, at t: TimeInterval) -> Blink? {
        guard closure >= thresholds.minClosure, closure <= thresholds.maxClosure else { return nil }
        if let last = lastBlinkAt, t - last < thresholds.refractory { return nil }
        lastBlinkAt = t
        blinkCount += 1
        return Blink(index: blinkCount, at: t, closure: closure, ear: ear)
    }

    /// Mean of whichever eyes were measured. Averaging rather than taking the
    /// minimum: the minimum makes a single mis-tracked eye look like a
    /// permanent wink, and a wink is not what this game is played with.
    static func fuse(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (l?, r?) where l.isFinite && r.isFinite: return (l + r) / 2
        case let (l?, _) where l.isFinite: return l
        case let (_, r?) where r.isFinite: return r
        default: return nil
        }
    }
}
