import Foundation
import SwiftUI
import VibeNotify

/// The user's **global** notification appearance — the layer every schedule
/// alert falls back to when its action says nothing about how it should look.
///
/// This replaces `NotificationPreferences.default`, a hardcoded struct that
/// nobody could change, as the bottom of the resolution stack. The order is:
///
/// 1. `GlobalNotificationSettings` — these values, set once in Settings.
/// 2. The action's own `parameters` — any appearance key present wins over the
///    global value for that key alone, never for the whole set.
///
/// So an action that specifies nothing gets the global look, and an action that
/// specifies `position: topRight` keeps `topRight` and inherits everything else.
/// `resolving(actionParameters:)` is the single place that rule is expressed.
///
/// ## Where these live
///
/// The durable copy is `Profile.preferences`, already a `map<string, string>`
/// on the wire (`proto/vibecare.proto`) and already round-tripped by
/// `ProfileService`, so this needed no proto change, no migration and no
/// backend work — and it syncs across devices instead of being stranded in one
/// machine's `UserDefaults`.
///
/// `UserDefaults` is still written, as a **mirror rather than a second source
/// of truth**: notifications can fire before the profile has finished loading
/// (and while the backend is unreachable), and reading them must not be async
/// or main-actor-bound. `hydrate(from:)` overwrites the mirror whenever a
/// profile arrives, so the server always wins on a conflict.
struct GlobalNotificationSettings: Equatable, Sendable {

  // MARK: - Stored

  var position: NotificationPosition
  var width: CGFloat
  var height: CGFloat
  var screenBlurEnabled: Bool
  var screenBlurIntensity: BlurIntensity
  /// Opacity of the black backdrop behind the blur, for `.interrupt` alerts
  /// only — an `.ambient` alert builds no backdrop window at all, so this is
  /// inert for one. See `screenDimRange` for why the bounds are what they are.
  var screenDim: Double
  /// What a full-screen alert puts behind itself: the user's own desktop
  /// blurred and dimmed (the default, and what every alert did before this
  /// existed), or one of the flat/gradient fields the library paints instead.
  ///
  /// Global-only, deliberately: there is no per-action override key for it and
  /// it is absent from `appearanceParameterKeys`. A break backdrop is a
  /// property of *this machine's* idea of restful, not of the routine that
  /// fired the alert, and every option is luminance-capped by the library
  /// (`Legibility.maxSafeLuminance`) so there is no unsafe value for an action
  /// to smuggle in anyway.
  var backdropStyle: BackdropStyle
  var autoDismissAfter: TimeInterval
  var moveable: Bool
  /// The word under a break countdown's number, used when an action sets
  /// `task_timer_seconds` without saying what to call the unit.
  var breakUnitLabel: String
  /// What a break countdown's centre says once it reaches zero.
  var breakCompletionLabel: String

  // MARK: - Bounds

  /// The range the dim slider may offer, mirroring
  /// `OverlayWindowManager.Configuration`'s own clamp (`0.1...0.95`) so the UI
  /// can never propose a value the library would silently rewrite. The floor is
  /// the minimum background alpha the private CGS blur call needs to composite
  /// at all; the ceiling stops short of an opaque backdrop, which would no
  /// longer read as a blur.
  static let screenDimRange: ClosedRange<Double> = 0.1...0.95

  /// The smallest dim at which white text is guaranteed to clear WCAG AA
  /// (4.5:1) over *any* desktop, worst case a pure white one. Derived once, in
  /// the library, as `Legibility.safeDim` — read from there rather than written
  /// as `0.55` so the two cannot drift.
  static let wcagSafeScreenDim: Double = Legibility.safeDim

  // MARK: - Init

  /// Spelled out because declaring `init(profilePreferences:)` below suppresses
  /// the synthesized memberwise initializer.
  init(
    position: NotificationPosition,
    width: CGFloat,
    height: CGFloat,
    screenBlurEnabled: Bool,
    screenBlurIntensity: BlurIntensity,
    screenDim: Double,
    backdropStyle: BackdropStyle = .blurredDesktop,
    autoDismissAfter: TimeInterval,
    moveable: Bool,
    breakUnitLabel: String,
    breakCompletionLabel: String
  ) {
    self.position = position
    self.width = width
    self.height = height
    self.screenBlurEnabled = screenBlurEnabled
    self.screenBlurIntensity = screenBlurIntensity
    self.screenDim = screenDim
    self.backdropStyle = backdropStyle
    self.autoDismissAfter = autoDismissAfter
    self.moveable = moveable
    self.breakUnitLabel = breakUnitLabel
    self.breakCompletionLabel = breakCompletionLabel
  }

  // MARK: - Fallback

  /// What a profile that has never been to the Settings screen gets. These are
  /// the values `NotificationPreferences.default` carried, with one addition:
  /// `screenDim` starts at the WCAG-safe threshold rather than at the library's
  /// floor, because an alert nobody can read is not a defensible default.
  static let fallback = GlobalNotificationSettings(
    position: .center,
    width: 450,
    height: 220,
    screenBlurEnabled: false,
    screenBlurIntensity: .medium,
    screenDim: wcagSafeScreenDim,
    // The blurred desktop, i.e. nothing about an existing alert changes until
    // the user picks something else.
    backdropStyle: .blurredDesktop,
    autoDismissAfter: 20,
    moveable: true,
    breakUnitLabel: "seconds",
    breakCompletionLabel: "Break complete"
  )

  // MARK: - Keys

  /// One key list, used for both `Profile.preferences` and the `UserDefaults`
  /// mirror. Namespaced so the profile map stays legible next to whatever else
  /// ends up in it.
  private enum Key {
    static let position = "notify.position"
    static let width = "notify.width"
    static let height = "notify.height"
    static let blurEnabled = "notify.blur_enabled"
    static let blurIntensity = "notify.blur_intensity"
    static let screenDim = "notify.screen_dim"
    static let backdropStyle = "notify.backdrop_style"
    static let autoDismissAfter = "notify.auto_dismiss_after"
    static let moveable = "notify.moveable"
    static let breakUnitLabel = "notify.break_unit_label"
    static let breakCompletionLabel = "notify.break_completion_label"

    static let prefix = "notify."
  }

  /// The action-parameter keys that count as *appearance*, i.e. the ones a
  /// per-action override owns and the ones the action editor's Advanced
  /// disclosure writes or removes as a set.
  ///
  /// Content keys (`title`, `body`, `svg_path`, `svg_width`, `svg_height`,
  /// `task_timer_seconds`) are deliberately absent: they are what the action is
  /// *about*, not how it looks, and they have no global counterpart.
  static let appearanceParameterKeys = [
    "position", "width", "height", "moveable",
    "auto_dismiss_after", "screen_blur_enabled", "screen_blur_intensity",
  ]

  /// Whether these parameters override the global appearance at all. The
  /// presence of the keys *is* the persisted override state — there is no
  /// separate "overridden" flag to keep in sync with them, and an action
  /// authored by the CLI or MCP that sets only `position` reads correctly here
  /// without having been written by this app.
  static func overridesAppearance(_ parameters: [String: String]) -> Bool {
    appearanceParameterKeys.contains { parameters[$0] != nil }
  }

  /// `parameters` with every appearance key removed, i.e. an action that
  /// inherits the global look entirely.
  static func clearingAppearance(_ parameters: [String: String]) -> [String: String] {
    var result = parameters
    for key in appearanceParameterKeys { result.removeValue(forKey: key) }
    return result
  }

  // MARK: - Reading

  /// The settings in force right now, read from the mirror. Cheap, synchronous
  /// and callable from any isolation — which is the whole reason the mirror
  /// exists (see the type's doc comment).
  static var current: GlobalNotificationSettings {
    let defaults = UserDefaults.standard
    var settings = fallback

    if let raw = defaults.string(forKey: Key.position),
      let position = NotificationPosition(rawValue: raw)
    {
      settings.position = position
    }
    if defaults.object(forKey: Key.width) != nil {
      settings.width = CGFloat(defaults.double(forKey: Key.width))
    }
    if defaults.object(forKey: Key.height) != nil {
      settings.height = CGFloat(defaults.double(forKey: Key.height))
    }
    if defaults.object(forKey: Key.blurEnabled) != nil {
      settings.screenBlurEnabled = defaults.bool(forKey: Key.blurEnabled)
    }
    if let raw = defaults.string(forKey: Key.blurIntensity),
      let intensity = BlurIntensity(rawValue: raw)
    {
      settings.screenBlurIntensity = intensity
    }
    if defaults.object(forKey: Key.screenDim) != nil {
      settings.screenDim = defaults.double(forKey: Key.screenDim)
    }
    if let raw = defaults.string(forKey: Key.backdropStyle),
      let style = BackdropStyle(rawValue: raw)
    {
      settings.backdropStyle = style
    }
    if defaults.object(forKey: Key.autoDismissAfter) != nil {
      settings.autoDismissAfter = defaults.double(forKey: Key.autoDismissAfter)
    }
    if defaults.object(forKey: Key.moveable) != nil {
      settings.moveable = defaults.bool(forKey: Key.moveable)
    }
    if let label = defaults.string(forKey: Key.breakUnitLabel), !label.isEmpty {
      settings.breakUnitLabel = label
    }
    if let label = defaults.string(forKey: Key.breakCompletionLabel), !label.isEmpty {
      settings.breakCompletionLabel = label
    }

    return settings.sanitized
  }

  /// Bounds enforced on the way *out* as well as on the way in: a value written
  /// by an older build, another device, or a hand-edited profile map still has
  /// to be one the renderer can use.
  private var sanitized: GlobalNotificationSettings {
    var copy = self
    copy.screenDim = min(max(screenDim, Self.screenDimRange.lowerBound), Self.screenDimRange.upperBound)
    copy.width = max(200, width)
    copy.height = max(120, height)
    copy.autoDismissAfter = max(1, autoDismissAfter)
    if copy.breakUnitLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      copy.breakUnitLabel = Self.fallback.breakUnitLabel
    }
    if copy.breakCompletionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      copy.breakCompletionLabel = Self.fallback.breakCompletionLabel
    }
    return copy
  }

  // MARK: - Profile round trip

  /// Reads whatever this profile has stored, leaving anything it never wrote at
  /// the fallback value.
  init(profilePreferences: [String: String]) {
    var settings = Self.fallback

    if let raw = profilePreferences[Key.position],
      let position = NotificationPosition(rawValue: raw)
    {
      settings.position = position
    }
    if let value = profilePreferences[Key.width].flatMap(Double.init) {
      settings.width = CGFloat(value)
    }
    if let value = profilePreferences[Key.height].flatMap(Double.init) {
      settings.height = CGFloat(value)
    }
    if let value = profilePreferences[Key.blurEnabled].flatMap(Bool.init) {
      settings.screenBlurEnabled = value
    }
    if let raw = profilePreferences[Key.blurIntensity],
      let intensity = BlurIntensity(rawValue: raw)
    {
      settings.screenBlurIntensity = intensity
    }
    if let value = profilePreferences[Key.screenDim].flatMap(Double.init) {
      settings.screenDim = value
    }
    // An unknown raw value — a style this build does not have, written by a
    // newer one on another device — falls back to the blurred desktop rather
    // than failing the whole hydration. Every option is safe; none is
    // load-bearing.
    if let raw = profilePreferences[Key.backdropStyle],
      let style = BackdropStyle(rawValue: raw)
    {
      settings.backdropStyle = style
    }
    if let value = profilePreferences[Key.autoDismissAfter].flatMap(Double.init) {
      settings.autoDismissAfter = value
    }
    if let value = profilePreferences[Key.moveable].flatMap(Bool.init) {
      settings.moveable = value
    }
    if let label = profilePreferences[Key.breakUnitLabel], !label.isEmpty {
      settings.breakUnitLabel = label
    }
    if let label = profilePreferences[Key.breakCompletionLabel], !label.isEmpty {
      settings.breakCompletionLabel = label
    }

    self = settings.sanitized
  }

  /// These settings as `Profile.preferences` entries, ready to be merged into
  /// whatever else the profile carries. Every key is always written, so a
  /// value returned to its default still propagates to the other devices
  /// rather than silently inheriting theirs.
  var profileEntries: [String: String] {
    let settings = sanitized
    return [
      Key.position: settings.position.rawValue,
      Key.width: String(Double(settings.width)),
      Key.height: String(Double(settings.height)),
      Key.blurEnabled: String(settings.screenBlurEnabled),
      Key.blurIntensity: settings.screenBlurIntensity.rawValue,
      Key.screenDim: String(settings.screenDim),
      Key.backdropStyle: settings.backdropStyle.rawValue,
      Key.autoDismissAfter: String(settings.autoDismissAfter),
      Key.moveable: String(settings.moveable),
      Key.breakUnitLabel: settings.breakUnitLabel,
      Key.breakCompletionLabel: settings.breakCompletionLabel,
    ]
  }

  /// `preferences` with these settings' entries applied, leaving every
  /// unrelated key untouched.
  func merged(into preferences: [String: String]) -> [String: String] {
    var result = preferences
    for (key, value) in profileEntries { result[key] = value }
    return result
  }

  /// Writes the mirror. Called after a successful edit and from
  /// `hydrate(from:)`.
  func persistLocally() {
    let defaults = UserDefaults.standard
    for (key, value) in profileEntries {
      switch key {
      case Key.width, Key.height, Key.screenDim, Key.autoDismissAfter:
        defaults.set(Double(value) ?? 0, forKey: key)
      case Key.blurEnabled, Key.moveable:
        defaults.set(value == "true", forKey: key)
      default:
        defaults.set(value, forKey: key)
      }
    }
  }

  /// Adopts a freshly loaded profile's settings into the mirror.
  ///
  /// A profile carrying none of these keys is left alone rather than reset: it
  /// is a profile that has never visited the Settings screen, not a profile
  /// that asked for the defaults, and clobbering the mirror would discard
  /// settings the user made while offline before they were ever synced.
  static func hydrate(from profilePreferences: [String: String]) {
    guard profilePreferences.keys.contains(where: { $0.hasPrefix(Key.prefix) }) else { return }
    GlobalNotificationSettings(profilePreferences: profilePreferences).persistLocally()
  }

  // MARK: - Resolution

  /// These settings as a `NotificationPreferences`, with no action layered on
  /// top — what an alert with no customisation whatsoever looks like.
  func basePreferences() -> NotificationPreferences {
    NotificationPreferences(
      position: position,
      width: width,
      height: height,
      moveable: moveable,
      autoDismissAfter: autoDismissAfter,
      screenBlurEnabled: screenBlurEnabled,
      screenBlurIntensity: screenBlurIntensity,
      // No `taskTimerSeconds`: a break countdown is something an action asks
      // for. These two only say what to *call* it when one does.
      taskTimerUnitLabel: breakUnitLabel,
      taskTimerCompletionLabel: breakCompletionLabel
    )
  }

  /// **The resolution rule.** Global settings are the defaults; any key present
  /// in `parameters` overrides them, key by key.
  ///
  /// The old version of this returned `nil` unless *some* customisation
  /// existed, which is what made an uncustomised alert fall through to the
  /// hardcoded `NotificationPreferences.default`. That test is wrong once
  /// globals exist: every notification now has preferences, they just may all
  /// come from the global layer.
  func resolving(actionParameters parameters: [String: String]) -> NotificationPreferences {
    let preferences = basePreferences()

    // Content — no global counterpart, so absent simply means absent.
    // `svg_path` carries the full URL for bundled icons and a file path for
    // custom ones; there is no separate bundled-id parameter any more.
    preferences.svgPath = parameters["svg_path"]
    preferences.svgWidth = parameters["svg_width"].flatMap(Double.init).map { CGFloat($0) }
    preferences.svgHeight = parameters["svg_height"].flatMap(Double.init).map { CGFloat($0) }
    preferences.title = parameters["title"]
    preferences.message = parameters["body"]

    // Appearance — global unless this action says otherwise.
    if let raw = parameters["position"], let value = NotificationPosition(rawValue: raw) {
      preferences.position = value
    }
    if let value = parameters["width"].flatMap(Double.init) {
      preferences.width = CGFloat(value)
    }
    if let value = parameters["height"].flatMap(Double.init) {
      preferences.height = CGFloat(value)
    }
    if let value = parameters["moveable"].flatMap(Bool.init) {
      preferences.moveable = value
    }
    if let value = parameters["auto_dismiss_after"].flatMap(Double.init) {
      preferences.autoDismissAfter = value
    }
    if let value = parameters["screen_blur_enabled"].flatMap(Bool.init) {
      preferences.screenBlurEnabled = value
    }
    if let raw = parameters["screen_blur_intensity"], let value = BlurIntensity(rawValue: raw) {
      preferences.screenBlurIntensity = value
    }

    // Break countdown: the duration is the action's alone (absent or
    // unparseable means no ring at all, unchanged), the labels fall back to the
    // global ones already seeded by `basePreferences()`.
    preferences.taskTimerSeconds = parameters["task_timer_seconds"].flatMap(Double.init)
    if let label = parameters["task_timer_unit_label"], !label.isEmpty {
      preferences.taskTimerUnitLabel = label
    }
    if let label = parameters["task_timer_completion_label"], !label.isEmpty {
      preferences.taskTimerCompletionLabel = label
    }

    // Web panel — the action's alone, with no global counterpart. What to load
    // during a break is content, not appearance, which is the same reason
    // `task_timer_seconds` has no global default either. The three modifiers
    // are inert without `web_url`; `VibeNotifyConfig` reads none of them once
    // it resolves to no panel.
    if let spec = parameters["web_url"], !spec.isEmpty {
      preferences.webURLSpec = spec
    }
    preferences.webPlacement = parameters["web_side"]
    preferences.webWidthFraction = parameters["web_width"].flatMap(Double.init).map { CGFloat($0) }
    if let value = parameters["web_autoplay"].flatMap(Bool.init) {
      preferences.webAutoplay = value
    }
    if let value = parameters["web_muted"].flatMap(Bool.init) {
      preferences.webMuted = value
    }
    if let value = parameters["web_loop"].flatMap(Bool.init) {
      preferences.webLoops = value
    }

    return preferences
  }
}
