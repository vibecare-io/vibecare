import Foundation
import VCPluginSDK

/// The one sanctioned way to write a diagnostic line from this file. Plain
/// `fputs`, never `FileHandle.standardError.write(_:)` — see the identical
/// rule and reasoning in every other file of this package.
private func sinkLog(_ message: String) {
    fputs("vibecheck: \(message)\n", stderr)
}

/// The subset of `VCHost` this plugin actually calls. Exists purely as a
/// unit-testing seam: `VCHost` dials a real gRPC socket in `connect()` and
/// cannot be constructed in a test, so tests inject a spy conforming to this
/// instead. `VCHost` itself needs no changes to conform — its `alert(_:)`
/// and `publish(topic:payload:)` already match this signature exactly.
///
/// Both members are used by two callers now: `HostSink` alerts and publishes
/// `vibecheck.behavior_detected.v1`, and `VisionRequest` publishes
/// `vision.request.v1`.
public protocol AlertHost: Sendable {
    func alert(_ a: VCAlert) async throws
    func publish(topic: String, payload: Data) async throws
}

extension VCHost: AlertHost {}

/// One confirmed detection, broadcast to every `/api/events` SSE subscriber
/// via `HostSink.events()`. Deliberately a thin wrapper around `BFRBEvent`
/// rather than reusing it directly: `count` and `behavior` are
/// `fired(_:count:behavior:)` arguments, not part of `BFRBEvent` itself, and
/// a subscriber needs all three to render "3rd nail-biting nudge today".
public struct DetectionBroadcast: Sendable {
    public let event: BFRBEvent
    public let count: Int
    public let behavior: BFRBBehavior

    public init(event: BFRBEvent, count: Int, behavior: BFRBBehavior) {
        self.event = event
        self.count = count
        self.behavior = behavior
    }
}

/// Production `DetectionSink`: fans every confirmed detection out to
/// `/api/events` SSE subscribers, then — unless `SnoozeGate` says the alert
/// should be suppressed — alerts every connected client and publishes to the
/// bus.
///
/// Lifted out of `DetectionEngine.swift` unchanged when that file was split
/// (vision-provider design §8): the engine decides that a detection
/// happened, this decides what the user sees about it, and those are
/// different jobs that were only ever in one file because the camera was
/// there too.
///
/// An actor, not a struct, because `attach(host:)` and the SSE continuation
/// registry both need actor-isolated mutable state. `host` is optional and
/// settable after construction rather than a required `init` parameter:
/// `main.swift`'s composition root must register HTTP routes — and with them
/// `DetectionEngine`, which needs a `DetectionSink` at construction — before
/// `VCHost.connect()` can be called at all (see that file's ordering
/// comment), so no live `VCHost` exists yet at the point this sink is built.
/// A nil host here only logs and still broadcasts to SSE, rather than
/// crashing, for the same "nothing in this plugin terminates the process"
/// discipline as everything else in it.
public actor HostSink: DetectionSink {
    private var host: (any AlertHost)?
    /// `fired` reads `preferences(for:)` and prefers the stored
    /// `title`/`message` over `behavior.label`/`behavior.nudge` when they
    /// are non-empty — otherwise the "Advanced: Alert Appearance" editor
    /// would persist to `alert-prefs.json` and do nothing.
    private let prefs: AlertPrefsStore
    private let snooze: SnoozeGate
    private var continuations: [UUID: AsyncStream<DetectionBroadcast>.Continuation] = [:]

    public init(prefs: AlertPrefsStore, snooze: SnoozeGate) {
        self.prefs = prefs
        self.snooze = snooze
    }

    /// Called once, from `main.swift`, right after `VCHost.connect()`
    /// returns.
    public func attach(host: any AlertHost) {
        self.host = host
    }

    /// A fan-out subscription for `/api/events`, same continuation-map shape
    /// as `VCHost.events()`.
    public func events() -> AsyncStream<DetectionBroadcast> {
        let (stream, continuation) = AsyncStream<DetectionBroadcast>.makeStream(
            of: DetectionBroadcast.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let key = UUID()
        continuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.dropContinuation(key) }
        }
        return stream
    }

    private func dropContinuation(_ key: UUID) {
        continuations.removeValue(forKey: key)
    }

    /// `nil` for both a never-set preference (`nil`) and an explicitly
    /// blanked one (`""`) — either way, the caller should fall back to the
    /// built-in copy rather than send core a blank title or body.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Encodes one behavior's `NotificationPreferences` into the blob that
    /// rides on `VCAlert.appearance`, so the client can render this
    /// plugin's alert the way the user configured it — the icon, position,
    /// size, blur and dismissal timing that the "Advanced: Alert
    /// Appearance" editor writes — instead of a generic banner.
    ///
    /// Why the appearance travels ON the alert rather than the client
    /// fetching `/api/alert-prefs`: a client that knew to fetch that URL
    /// would contain vibecheck-specific code, and the whole reason a plugin
    /// can ship without a client release is that no client contains
    /// per-plugin code. An opaque field on a message any plugin can send
    /// keeps that true.
    ///
    /// The bytes are produced by the SDK's `VCAlertAppearance`, not by this
    /// package: the schema is the SDK's to state (and to keep sorted and
    /// deterministic), and `NotificationPreferences` is this plugin's own
    /// persisted config with its own on-disk format and editor UI. The two
    /// coincide field-for-field today, which is exactly why they must not
    /// be the same type — a change to what vibecheck persists would
    /// otherwise silently become a change to what every client decodes.
    /// `wireAppearance` below is the seam where the two meet.
    ///
    /// **These exact bytes are pinned twice**, here by
    /// `HostSinkTests.theEncodedAppearanceHasTheShapeTheClientDecodes` and
    /// on the other side by the client's `PluginAlertAppearanceTests`.
    /// Neither side can import the other's type, so that pair IS the
    /// cross-language contract, and the cutover to the vision bus changed
    /// nothing about it.
    ///
    /// Returns `nil` if encoding somehow fails, which sends no appearance
    /// at all rather than a broken one — the client then renders its
    /// default alert, which is worse-looking but correct. Nothing here
    /// throws out to the caller: a presentation detail must never cost the
    /// user the alert itself.
    static func encodeAppearance(_ preference: NotificationPreferences) -> String? {
        guard let encoded = preference.wireAppearance.encoded() else {
            sinkLog("could not encode alert appearance; sending the alert unstyled")
            return nil
        }
        return encoded
    }

    public func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        // Broadcast first and unconditionally: a snooze suppresses the popup
        // alert, not the fact that a detection happened, and an SSE
        // subscriber (the plugin's own tab, a future TUI client) wants the
        // latter regardless.
        let broadcast = DetectionBroadcast(event: event, count: count, behavior: behavior)
        for continuation in continuations.values {
            continuation.yield(broadcast)
        }

        guard !(await snooze.isActive()) else { return }
        guard let host else {
            sinkLog("detection fired before a host was attached; alert dropped (SSE still got it)")
            return
        }

        // Stored preferences win when the user actually set them; an empty
        // string (never explicitly cleared vs. never touched are
        // indistinguishable through this API today) falls back to the
        // built-in copy exactly like a `nil` does, rather than showing a
        // blank title or body.
        let preference = await prefs.preferences(for: behavior)
        let title = Self.nonEmpty(preference.title) ?? behavior.label
        let message = Self.nonEmpty(preference.message) ?? behavior.nudge

        // The `Ordinal.format(count)` suffix is appended REGARDLESS of
        // whether `message` came from the user or the built-in default —
        // deliberately, not merely preserving old behavior for the
        // fallback case. The count is what makes an alert feel responsive
        // to what's actually happening ("3rd nudge today") rather than a
        // static, repeated banner; a user who wrote their own encouraging
        // message presumably still wants to know it's counting, not lose
        // that context because they customized the wording around it.
        //
        // "warn" (not "info") so the banner holds 8s instead of 3s — only
        // "info" and "warn" exist; anything else silently renders as info.
        //
        // The SAME `preference` also rides along as `appearance`, so the
        // client renders this alert with the user's configured icon,
        // position, size and blur rather than a generic banner. Sent on
        // every detection alert, not only customized ones:
        // `AlertPrefsStore` seeds every behavior with
        // `NotificationPreferences.default(for:)`, which IS the rich look
        // (centered, 450x220, light screen blur, the behavior's own icon).
        // Withholding it until the user visits the editor would mean the
        // out-of-the-box alert is the plain one and the good-looking alert
        // is a hidden setting.
        let alert = VCAlert(
            title: title,
            body: "\(message) — \(Ordinal.format(count)) nudge today",
            level: "warn",
            actions: [
                VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10"),
                VCAlertAction(label: "Turn off", url: "api/config/disable"),
            ],
            appearance: Self.encodeAppearance(preference)
        )
        // Neither failure is fatal: core may be mid-reconnect. Log and
        // continue — a dropped alert is not a reason to crash the detector.
        do {
            try await host.alert(alert)
        } catch {
            sinkLog("alert failed: \(error)")
        }
        do {
            try await host.publish(topic: "vibecheck.behavior_detected.v1",
                                    payload: Data(behavior.rawValue.utf8))
        } catch {
            sinkLog("publish failed: \(error)")
        }
    }
}
