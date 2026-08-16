import Foundation

/// The presentation hints a plugin may attach to one `VCAlert` — the icon,
/// size, position, blur and dismissal timing the rendering client should use
/// instead of its default banner.
///
/// ## What this is for
///
/// `VCAlert.appearance` travels to the client as an opaque JSON string; core
/// forwards it verbatim and never parses it (an alert's look is product
/// semantics, and the kernel has none). That opacity is deliberate — it is
/// what lets a plugin restyle its own alerts without a single line of
/// plugin-specific code in any client — but it also means the schema is a
/// convention rather than a compiler-checked type. **This type IS that
/// schema**, written down once, so a plugin never has to hand-roll the JSON
/// or copy it out of a client's source.
///
/// ## Worked example
///
/// ```swift
/// var look = VCAlertAppearance()
/// look.svgPath = "icons/nail-biting.svg"   // relative -> resolved under /p/<id>/
/// look.svgWidth = 220
/// look.svgHeight = 150
/// look.position = .center
/// look.width = 450
/// look.height = 220
/// look.autoDismissAfter = 20               // seconds
/// look.screenBlurEnabled = true
/// look.screenBlurIntensity = .light
///
/// try await host.alert(VCAlert(
///     title: "Hands off",
///     body: "3rd nudge today",
///     level: "warn",
///     actions: [VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10")],
///     appearance: look
/// ))
/// ```
///
/// ## The absence rule
///
/// Every property is `Optional` and **absence is meaningful**: a property
/// left `nil` is omitted from the JSON entirely, and the client fills it
/// from its own default. There is no way to say "use zero" by leaving a
/// field out, and no way to say "use the default" by sending `0` or `null` —
/// so never substitute a zero or a placeholder for a value you do not have
/// an opinion about. Set only what you actually want to change.
///
/// ## Two things that will surprise you
///
/// - A blob whose keys match **none** of the ones below is rejected by the
///   client, which then renders its plain default banner. An all-`nil`
///   appearance therefore encodes to `{}` and is, in practice, the same as
///   sending no appearance at all — it is not a request to strip styling.
/// - `title` and `message` are part of the schema and are accepted by the
///   client, but are deliberately **not applied**: the alert's own `title`
///   and `body` always win. See those properties for why they exist anyway.
///
/// The complete valid value set for every field is stated on the property
/// itself; nothing here needs cross-referencing against a client's source.
public struct VCAlertAppearance: Sendable, Codable, Equatable {

    // MARK: - Enumerated vocabularies

    /// Where on screen the alert is placed.
    ///
    /// Complete valid set: `.center`, `.topLeft`, `.topRight`,
    /// `.bottomLeft`, `.bottomRight` — wire values are the case names
    /// verbatim (`"center"`, `"topLeft"`, …). A client default of `center`
    /// applies when the field is omitted.
    ///
    /// This is an enum rather than a `String` precisely so `"topRight"`
    /// spelled `"top-right"` or `"topright"` is a compile error here rather
    /// than a silently ignored field at render time.
    public enum Position: String, Sendable, Codable, CaseIterable, Equatable {
        case center
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    /// How strongly the screen behind the alert is blurred, when
    /// `screenBlurEnabled` is `true`.
    ///
    /// Complete valid set: `.light`, `.medium`, `.heavy` — wire values are
    /// the case names verbatim. Client default when omitted: `medium`.
    /// Ignored entirely unless `screenBlurEnabled == true`.
    public enum BlurIntensity: String, Sendable, Codable, CaseIterable, Equatable {
        case light
        case medium
        case heavy
    }

    // MARK: - Icon

    /// Identifier of an icon bundled with the *client* (not with the
    /// plugin), e.g. `"bell"`. There is no enumerated list here on purpose:
    /// the catalogue belongs to whichever client renders the alert and can
    /// grow without an SDK release. Prefer `svgPath` — an icon the plugin
    /// ships itself renders identically everywhere.
    ///
    /// Omitted when `nil`. Default: the client's own icon choice.
    public var bundledIconId: String?

    /// Path or URL to an SVG the alert should show.
    ///
    /// Two accepted forms:
    /// - **Absolute** — `https://…`, `http://…`, `file://…`, or `/abs/path`.
    /// - **Plugin-relative** — anything else, e.g. `"icons/nail-biting.svg"`.
    ///   The client resolves it against the plugin's own mount, `/p/<id>/`,
    ///   so the example above is fetched from `/p/<id>/icons/nail-biting.svg`.
    ///
    /// Plugin-relative is almost always what you want: a plugin cannot know
    /// the port core assigned it, so a relative path is the only self-hosted
    /// icon reference it can honestly send. Serve the file from your own
    /// HTTP router.
    ///
    /// Omitted when `nil`. Default: no SVG.
    public var svgPath: String?

    /// Rendered width of `svgPath`, in points. Omitted when `nil`; the
    /// client then picks its own size. Has no effect without `svgPath`.
    public var svgWidth: Double?

    /// Rendered height of `svgPath`, in points. Omitted when `nil`; the
    /// client then picks its own size. Has no effect without `svgPath`.
    public var svgHeight: Double?

    // MARK: - Geometry

    /// Screen placement. See `Position` for the complete valid set.
    /// Omitted when `nil`; client default `center`.
    public var position: Position?

    /// Alert window width in points. Omitted when `nil`; typical client
    /// default is `450`.
    public var width: Double?

    /// Alert window height in points. Omitted when `nil`; typical client
    /// default is `220`.
    public var height: Double?

    /// Whether the user may drag the alert around the screen. Omitted when
    /// `nil`; typical client default `true`.
    public var moveable: Bool?

    /// How long the alert stays up before dismissing itself, **in seconds**.
    /// Omitted when `nil`; typical client default `20`. Note that this is
    /// seconds as a `Double`, not milliseconds.
    public var autoDismissAfter: TimeInterval?

    // MARK: - Screen blur

    /// Whether to blur the screen behind the alert. Omitted when `nil`;
    /// typical client default `false`. `screenBlurIntensity` is only
    /// consulted when this is `true`.
    public var screenBlurEnabled: Bool?

    /// Blur strength. See `BlurIntensity` for the complete valid set.
    /// Omitted when `nil`; client default `medium`. Meaningless unless
    /// `screenBlurEnabled` is `true`.
    public var screenBlurIntensity: BlurIntensity?

    // MARK: - Text (accepted, but not applied)

    /// Accepted by the client and **deliberately not rendered**: the
    /// enclosing `VCAlert.title` always wins.
    ///
    /// It exists so a plugin whose persisted appearance preferences happen
    /// to include wording can forward them verbatim without stripping
    /// fields. Do not reach for it to set an alert's title — put the text in
    /// `VCAlert.title`, which is also the only place you can put something
    /// computed at fire time (a running count, say).
    public var title: String?

    /// Accepted by the client and **deliberately not rendered**: the
    /// enclosing `VCAlert.body` always wins. Same rationale as `title`.
    public var message: String?

    // MARK: - Construction

    /// Every parameter defaults to `nil`, i.e. "no opinion, use the client
    /// default". Set only the ones you mean — see the absence rule on the
    /// type.
    public init(
        bundledIconId: String? = nil,
        svgPath: String? = nil,
        svgWidth: Double? = nil,
        svgHeight: Double? = nil,
        position: Position? = nil,
        width: Double? = nil,
        height: Double? = nil,
        moveable: Bool? = nil,
        autoDismissAfter: TimeInterval? = nil,
        screenBlurEnabled: Bool? = nil,
        screenBlurIntensity: BlurIntensity? = nil,
        title: String? = nil,
        message: String? = nil
    ) {
        self.bundledIconId = bundledIconId
        self.svgPath = svgPath
        self.svgWidth = svgWidth
        self.svgHeight = svgHeight
        self.position = position
        self.width = width
        self.height = height
        self.moveable = moveable
        self.autoDismissAfter = autoDismissAfter
        self.screenBlurEnabled = screenBlurEnabled
        self.screenBlurIntensity = screenBlurIntensity
        self.title = title
        self.message = message
    }

    // MARK: - Wire encoding

    /// The wire key for each property, spelled out rather than synthesized.
    ///
    /// These strings are the cross-process contract; the Swift property
    /// names merely happen to match today. Pinning them here means renaming
    /// a property is a local refactor instead of a silent schema break that
    /// surfaces as "the client stopped styling my alerts".
    private enum CodingKeys: String, CodingKey {
        case bundledIconId, svgPath, svgWidth, svgHeight
        case position, width, height, moveable, autoDismissAfter
        case screenBlurEnabled, screenBlurIntensity
        case title, message
    }

    /// The exact bytes to put on `VCAlert.appearance`.
    ///
    /// Keys are emitted in sorted order, so the same appearance always
    /// produces the same string: the blob ends up in logs and in test
    /// expectations on both sides of the process boundary, and an ordering
    /// that shifted between runs would make both unreadable.
    ///
    /// `nil` properties are omitted outright — never emitted as `null` or as
    /// a zero — because omission is how this schema says "use the client
    /// default". An appearance with nothing set encodes to `{}`, which the
    /// client rejects in favour of its default banner.
    ///
    /// Returns `nil` only if JSON encoding fails, which cannot happen for
    /// these value types. It is surfaced rather than force-unwrapped so a
    /// caller can send the alert unstyled instead of crashing: a
    /// presentation detail must never cost the user the alert itself.
    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else {
            vcLog("sdk: could not encode VCAlertAppearance; the alert will be sent unstyled")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Attaching an appearance to an alert

extension VCAlert {
    /// Builds an alert with a typed appearance, so the caller never touches
    /// JSON.
    ///
    /// This encodes `appearance` immediately into the raw
    /// `VCAlert.appearance` string, which remains the single storage and the
    /// only thing that goes on the wire. **Precedence**: because there is
    /// exactly one stored field, whichever assignment happens last wins —
    /// this initializer overwrites any raw string, and assigning
    /// `alert.appearance = "…"` afterwards overwrites what this encoded.
    /// There is no hidden second source that could disagree with the bytes
    /// actually sent.
    ///
    /// The raw `init(title:body:level:actions:appearance: String?)` is
    /// untouched and keeps working for callers that already build their own
    /// JSON.
    public init(
        title: String,
        body: String,
        level: String = "info",
        actions: [VCAlertAction] = [],
        appearance: VCAlertAppearance
    ) {
        self.init(title: title, body: body, level: level, actions: actions,
                  appearance: appearance.encoded())
    }

    /// Replaces this alert's appearance with the encoded form of `appearance`.
    ///
    /// Same single-storage precedence as the initializer above: this
    /// overwrites whatever `appearance` held, raw or typed. A failed
    /// encoding (impossible in practice) clears the field, sending the alert
    /// unstyled rather than broken.
    public mutating func setAppearance(_ appearance: VCAlertAppearance) {
        self.appearance = appearance.encoded()
    }

    /// A copy of this alert carrying `appearance`, for the common
    /// build-then-style shape. See `setAppearance(_:)` for precedence.
    public func styled(_ appearance: VCAlertAppearance) -> VCAlert {
        var copy = self
        copy.setAppearance(appearance)
        return copy
    }
}
