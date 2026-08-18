import Foundation
import SwiftUI
import VibeNotify
import Logging

// MARK: - BlurIntensity to VibeNotify Conversion
extension BlurIntensity {
    /// Convert VibeCare BlurIntensity to VibeNotify ScreenBlurIntensity.
    ///
    /// One of the three type-translation boundaries between VibeCare's own
    /// vocabulary and VibeNotify's. Live again as of global notification
    /// settings: `VibeNotifyConfig.windowConfiguration` hand-writes the
    /// `.interrupt` window `Configuration` rather than taking
    /// `AlertMode`'s factory wholesale, precisely so the user's chosen blur
    /// intensity and screen dim reach the backdrop. `.ambient` still builds no
    /// blur window, so intensity remains inert for that mode.
    var vibeNotifyIntensity: ScreenBlurIntensity {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        }
    }
}

private extension String {
  var nonEmpty: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}

/// Centralized configuration for VibeNotify notifications
/// Provides consistent styling and helper methods for VibeCare notifications
enum VibeNotifyConfig {

  // MARK: - Brand Colors

  static let brandAccentColor = Color.accentColor

  // MARK: - Default Settings

  static let defaultDismissDelay: TimeInterval = 8.0
  static let quickDismissDelay: TimeInterval = 3.0
  static let defaultBannerHeight: CGFloat = 120
  static let compactBannerHeight: CGFloat = 80
  /// The SF Symbol size a schedule with no configured SVG falls back to. Large
  /// enough to read as the alert's illustration rather than a decoration, and
  /// scaled down by `Illustration.fitted(in:)` if the window is too small for
  /// it.
  static let fallbackSymbolPointSize: CGFloat = 56

  // MARK: - Logger

  private static let logger = Logger(label: "com.vibecare.vibe-notify-config")

  // MARK: - Plugin web panels

  /// How a `plugin:<id>/<path>` web-panel spec becomes a loadable URL, set by
  /// the plugin shell once its roster is live.
  ///
  /// A hook rather than a direct call because the roster lives on
  /// `PluginShellService`, which is a `@StateObject` owned by `Dashboard` and
  /// has no singleton — and should not grow one for this. It is also genuinely
  /// dynamic: the base URL and the session token both change when core
  /// restarts, so this must be read at delivery time and never cached.
  ///
  /// `nil` until the shell starts, which is the honest answer for an alert
  /// that fires before the plugin list exists: no panel, rather than a panel
  /// pointed at nothing.
  @MainActor static var pluginWebURLResolver: ((_ pluginID: String, _ path: String) -> URL?)?

  /// A `web_url` action parameter resolved to something a web view can load.
  ///
  /// Two accepted forms, and everything else is rejected rather than guessed
  /// at. In particular a bare `example.com` is *not* upgraded to
  /// `https://example.com`: `URL(string:)` accepts it happily as a relative
  /// URL, the web view then fails to load it, and the user gets a blank panel
  /// with no explanation. A log line and no panel is the better failure.
  @MainActor
  static func resolveWebURL(_ spec: String) -> URL? {
    let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.hasPrefix("plugin:") {
      let body = String(trimmed.dropFirst("plugin:".count))
      // `blink-jump` and `blink-jump/index.html` both work; the id is
      // everything up to the first slash.
      let separator = body.firstIndex(of: "/")
      let pluginID = separator.map { String(body[body.startIndex..<$0]) } ?? body
      let path = separator.map { String(body[body.index(after: $0)...]) } ?? ""
      guard !pluginID.isEmpty else {
        logger.error("web_url names no plugin", metadata: ["web_url": "\(spec)"])
        return nil
      }
      guard let resolver = pluginWebURLResolver else {
        logger.error(
          "web_url names a plugin but the plugin shell has not started; showing no panel",
          metadata: ["plugin": "\(pluginID)"])
        return nil
      }
      guard let url = resolver(pluginID, path) else {
        logger.error(
          "web_url names a plugin that is not in the roster; showing no panel",
          metadata: ["plugin": "\(pluginID)"])
        return nil
      }
      return url
    }

    guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"),
          let url = URL(string: trimmed)
    else {
      logger.error(
        "web_url is neither an http(s) URL nor plugin:<id>; showing no panel",
        metadata: ["web_url": "\(spec)"])
      return nil
    }
    return url
  }

  // MARK: - Ambient Window Height

  /// The window height an `.ambient` rich alert needs, which is not the height
  /// the user — or a plugin appearance — authored.
  ///
  /// `.interrupt` needs no such calculation; it *is* the screen. `.ambient` is a
  /// fixed-size window, and the rich renderer clips content that does not fit
  /// rather than growing the window — deliberately, because an
  /// `NSHostingView` free to publish its content's height resized an `.ambient`
  /// window to 2289pt tall. Every authored height in this app predates that
  /// renderer: they were chosen against one with no content padding, no
  /// set title and no half-height illustration cap. At the default 450x220 the
  /// rich renderer clips its own illustration at the top and everything below
  /// the message at the bottom. So an authored height is a floor, not a size.
  ///
  /// Erring high is close to free: the window is fully transparent and the
  /// content is centred in it, so the only consequences are a larger
  /// click-to-dismiss area and, at a corner position, content sitting a little
  /// further from the corner. Erring low costs a button nobody can click.
  ///
  /// `min(illustrationHeight, chrome)` is the renderer's own rule rather than a
  /// guess: `RichNotification.Illustration.fitted(in:)` scales an illustration
  /// taller than half the window down to fit, so past `chrome` the window stops
  /// growing with the picture and settles at twice the chrome.
  ///
  /// Calibrated by rendering `RichNotificationView` — with a live
  /// `NotificationClock` in its environment, since the clock's own row costs
  /// height — at scale 1, and finding the smallest height at which no ink
  /// touches the frame edge. Over illustration heights of 56/150/200/300pt,
  /// messages of one to five lines, and widths of 300/350/450pt, the worst cases
  /// were 248pt of chrome without a button row and 286pt with one. Both worst
  /// cases are a five-line message, which is not hypothetical: it is what the
  /// customization sheet's preview substitutes when no message is set.
  ///
  /// **Re-measured after the renderer's ambient type and spacing scale changed**
  /// (VibeNotify `RichMetrics.ambient`: 22pt padding, a 19pt title, a 13pt
  /// message and grouped rather than uniform gaps, replacing a flat 28/26/15/22).
  /// The same sweep now yields 248 without buttons and **276** with them — the
  /// stack got tighter, so both constants below remain floors with room to
  /// spare and neither is changed. Only this prose was stale: it described the
  /// old scale, and a comment that names four numbers none of which the renderer
  /// still uses is worse than no comment.
  static func richAmbientHeight(illustrationHeight: CGFloat, hasButtons: Bool) -> CGFloat {
    let chrome = hasButtons ? richChromeWithButtons : richChrome
    return chrome + min(illustrationHeight, chrome)
  }

  /// Room for everything the rich renderer draws that is not the illustration:
  /// the content padding, the title, the message, the gaps between elements and
  /// the dismiss clock's own row — all of them now sourced from VibeNotify's
  /// `RichMetrics.ambient` rather than from literals repeated here. Measured
  /// worst case 248 (see above); the margin is for a message longer than any
  /// measured.
  private static let richChrome: CGFloat = 264
  /// `richChrome` with a row of action buttons — measured worst case 276.
  private static let richChromeWithButtons: CGFloat = 304

  // MARK: - Schedule Notification

  @MainActor
  @discardableResult
  static func showScheduleNotification(
    scheduleName: String,
    routineName: String,
    scheduledTime: Date,
    notes: String? = nil,
    priority: NotificationPriority = .normal,
    preferences: NotificationPreferences? = nil
  ) -> UUID? {
    // Use the caller's preferences, or the user's global notification settings
    // — no longer `NotificationPreferences.default`, a hardcoded struct nobody
    // could change. See `GlobalNotificationSettings` for the resolution order.
    let prefs = preferences ?? GlobalNotificationSettings.current.basePreferences()

    logger.debug("🔍 showScheduleNotification - START", metadata: [
      "svgPath": "\(prefs.svgPath ?? "nil")",
      "svgWidth": "\(prefs.svgWidth?.description ?? "nil")",
      "svgHeight": "\(prefs.svgHeight?.description ?? "nil")",
      "svgSize": "\(prefs.svgSize?.debugDescription ?? "nil")",
      "resolvedSVGPath": "\(prefs.resolvedSVGPath ?? "nil")"
    ])

    // Format title and message using preferences
    let title = prefs.formatTitle(scheduleName: scheduleName, routineName: routineName)
    let message = prefs.formatMessage(
      scheduleName: scheduleName,
      routineName: routineName,
      scheduledTime: scheduledTime
    )

    let notificationId = showNotification(
      preferences: prefs,
      title: title,
      message: message,
      defaultSystemIcon: "bell.badge.fill",
      priority: priority
    )
    logger.debug("🔍 showScheduleNotification - END", metadata: ["notificationId": "\(notificationId?.uuidString ?? "nil")"])
    return notificationId
  }

  // MARK: - Shared Notification Renderer

  /// The shared VibeNotify builder core used by both schedule notifications
  /// and the VibeCheck detection alert. Takes already-resolved `title`/`message`
  /// and a `defaultSystemIcon` fallback for when no SVG icon is configured.
  @MainActor
  @discardableResult
  private static func showNotification(
    preferences prefs: NotificationPreferences,
    title: String,
    message: String,
    defaultSystemIcon: String,
    priority: NotificationPriority
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    // Illustration: SVG (url/file) if configured, else the caller's default
    // system icon as an SF Symbol. Deliberately an `Illustration.symbol(...)`
    // rather than a `StandardNotification.IconType`: the rich renderer does not
    // recognise the latter as an illustration at all, so the no-SVG case — what
    // every unconfigured schedule gets — would render without a picture. A nil
    // `color` means "the title colour", i.e. whatever is legible over the
    // scrim the renderer drew.
    let fallbackIllustration = RichNotification.Illustration.symbol(
      defaultSystemIcon, pointSize: fallbackSymbolPointSize, color: nil)
    let illustration: RichNotification.Illustration = {
      guard let svgPath = prefs.resolvedSVGPath, let svgSize = prefs.svgSize else {
        return fallbackIllustration
      }
      if svgPath.hasPrefix("http://") || svgPath.hasPrefix("https://") {
        guard let url = URL(string: svgPath) else { return fallbackIllustration }
        return .svg(.url(url), size: svgSize)
      }
      return .svg(.filePath(svgPath), size: svgSize)
    }()

    // A task-timer duration rides along on the action's parameters
    // (`task_timer_seconds`, with optional `task_timer_unit_label` /
    // `task_timer_completion_label`) — see `NotificationPreferences`. Absent
    // or unparseable means `nil` here too, which is what keeps an action with
    // no task timer rendering exactly as it did before this existed: no
    // `.taskTimer(...)` call below, no ring.
    let taskTimer: TaskTimer? = prefs.taskTimerSeconds.map { seconds in
      TaskTimer(
        duration: seconds,
        unitLabel: prefs.taskTimerUnitLabel ?? "seconds",
        completionLabel: prefs.taskTimerCompletionLabel ?? "Break complete"
      )
    }

    // The blur toggle is already the user's way of saying "take over my
    // screen for this", so it selects the alert mode rather than a lone window
    // knob. `.interrupt` dims the whole screen and picks text colours against
    // that dim; the old pre-rich code pinned a light blur at 0.1 and chose
    // text from the system appearance, which is exactly how a title landed
    // invisible over a dark terminal.
    //
    // A task timer forces `.interrupt` regardless of `screenBlurEnabled`.
    // `RichNotification.effectiveTaskTimer` returns `nil` in `.ambient` by
    // design — a labelled ring reads as a task, and ambient alerts have
    // none — so an action that set `task_timer_seconds` but left
    // `screen_blur_enabled: false` would otherwise get no ring at all and no
    // error to explain why. A duration the caller explicitly asked for is a
    // stronger signal than a blur flag that may just be an unconsidered
    // default, so this upgrades rather than silently drops the ring.
    //
    // A web panel forces it for the same reason: `effectiveWebPanel` is nil in
    // `.ambient`, so the action would get no panel and no explanation.
    let webPanel: WebPanel? = prefs.webURLSpec
      .flatMap(resolveWebURL)
      .map { url in
        WebPanel(
          url: url,
          placement: prefs.webPlacement == "trailing" ? .trailing : .leading,
          widthFraction: prefs.webWidthFraction ?? WebPanel.defaultWidthFraction,
          allowsAutoplay: prefs.webAutoplay)
      }

    let mode: AlertMode =
      (taskTimer != nil || webPanel != nil || prefs.screenBlurEnabled) ? .interrupt : .ambient

    var buttons: [StandardNotification.Button] = []
    var autoDismiss: StandardNotification.AutoDismiss?

    if let taskTimer {
      if !prefs.screenBlurEnabled {
        logger.info(
          "task_timer_seconds set without screen_blur_enabled; upgrading to .interrupt so the ring is visible",
          metadata: ["duration": "\(taskTimer.duration)"]
        )
      }
      buttons = [
        StandardNotification.Button(title: "Done", style: .primary, action: {}),
        StandardNotification.Button(title: "Skip", style: .secondary, action: {}),
      ]
      // `auto_dismiss_after` is deliberately NOT forwarded here. A task timer
      // and an auto-dismiss are sequential phases, not a race — the task
      // runs first and alone, and the dismiss clock only arms once it hits
      // zero, so honouring both would total `duration + delay` (e.g. the
      // 20-20-20 action's 20s task + 25s dismiss = 45s on screen), which is
      // very unlikely to be what an author who set a task duration meant.
      // Leaving `AutoDismiss` unset lets the library's own short
      // `completionHold` (1.5s) govern how long the completion/acknowledgement
      // label holds before the window closes — an honest, brief beat instead
      // of a silent 45-second alert.
      if let autoDismissAfter = prefs.autoDismissAfter {
        logger.debug(
          "ignoring auto_dismiss_after because a task timer is present",
          metadata: ["auto_dismiss_after": "\(autoDismissAfter)"]
        )
      }
    } else if webPanel != nil {
      // A web panel with no task timer would otherwise be an alert nobody can
      // keep: no buttons are added above, `RichNotificationView` suppresses
      // click-anywhere-to-dismiss whenever a panel is present, and the `else`
      // branch below would close it after `quickDismissDelay` — three seconds
      // of a video, then gone. Give it a way out and no deadline instead.
      buttons = [StandardNotification.Button(title: "Close", style: .primary, action: {})]
    } else {
      autoDismiss = StandardNotification.AutoDismiss(
        delay: prefs.autoDismissAfter ?? quickDismissDelay, indicator: .none)
    }

    let notification = RichNotification(
      illustration: illustration,
      webPanel: webPanel,
      title: title,
      message: message,
      // Only with a panel, and only because the panel is what takes
      // click-anywhere away. Without it the sentence would name an escape the
      // renderer does not offer, which is worse than saying nothing.
      footnote: webPanel != nil ? "Press ESC to skip" : nil,
      buttons: buttons,
      taskTimer: taskTimer,
      autoDismiss: autoDismiss,
      mode: mode
    )

    // The authored height is a floor — see `richAmbientHeight`. Computed
    // unconditionally rather than branched on the mode because `.interrupt`
    // ignores width and height entirely (it takes the whole screen), so there
    // is nothing for a branch to protect. `hasButtons` reserves the extra row
    // height only for the Done/Skip pair a task timer adds — a plain schedule
    // alert still has none.
    let height = max(
      CGFloat(prefs.height ?? 0),
      richAmbientHeight(
        // The height of the picture as the renderer will be asked to draw it.
        // The invalid-URL branch above falls back to a symbol while `svgSize`
        // is still set, so that one case reserves the SVG's room for a smaller
        // symbol — over-reserving, which is the harmless direction.
        illustrationHeight: prefs.svgSize?.height ?? fallbackSymbolPointSize,
        hasButtons: taskTimer != nil
      )
    )

    let (configuration, effectiveDim) = windowConfiguration(
      mode: mode, prefs: prefs, height: height)

    // `OverlayWindowManager.show` rather than `VibeNotify.shared.showRich`,
    // for one reason: `showRich` builds `RichNotificationView` without an
    // `effectiveDim`, so the renderer assumes whatever `AlertMode` implies —
    // a flat `Legibility.safeDim` (0.55) for `.interrupt`. That assumption is
    // exactly what stops being true once the dim is a user setting: at a dim
    // of 0.2 the renderer would conclude the backdrop is already safe and skip
    // the local feathered scrim, leaving white text over a barely-dimmed
    // desktop. Passing the real dim is what `RichNotificationView`'s
    // `effectiveDim` parameter exists for, and it is the only knob `showRich`
    // does not forward. Everything else here is what `showRich` does:
    // `notification.countdown` for the clock, `Legibility.backdrop` to decide
    // whether the blur window should exist at all under Reduce Transparency.
    let id = UUID()
    OverlayWindowManager.shared.show(
      id: id,
      configuration: configuration,
      countdown: notification.countdown
    ) {
      RichNotificationView(
        notification: notification,
        effectiveDim: effectiveDim,
        // Off the configuration the backdrop window is built from, never a
        // second read of the settings: the window and the renderer have to
        // agree about what is behind the text.
        backdropStyle: configuration.backdropStyle
      ) {
        OverlayWindowManager.shared.dismiss(id: id)
      }
    }
    return id
  }

  // MARK: - Window Configuration

  /// The window `Configuration` for `mode`, and the backdrop dim the renderer
  /// should believe is in force.
  ///
  /// Hand-written memberwise literals rather than `Configuration.interrupt(...)`
  /// / `.ambient(...)`, which is what `OverlayWindowManager.Configuration`'s own
  /// doc comment asks consumers to do — and necessary here regardless, because
  /// neither factory takes the two fields this feature exists to make
  /// adjustable: `.interrupt` pins `screenDim` to `Legibility.safeDim` and
  /// `.ambient` pins `isMoveable` to false. Every other field is copied from the
  /// corresponding factory verbatim; see `AlertMode.swift` for why each is what
  /// it is.
  @MainActor
  private static func windowConfiguration(
    mode: AlertMode,
    prefs: NotificationPreferences,
    height: CGFloat
  ) -> (OverlayWindowManager.Configuration, Double) {
    let reduceTransparency = Legibility.Accessibility.reduceTransparency
    // The user's chosen break backdrop is global, like the dim beside it, and
    // is read from the same place for the same reason: it is not something an
    // action can override, so it never rides in on `prefs`.
    let backdropStyle = GlobalNotificationSettings.current.backdropStyle
    let backdrop = Legibility.backdrop(
      for: mode, reduceTransparency: reduceTransparency, style: backdropStyle)

    switch mode {
    case .interrupt:
      // An opaque backdrop means Reduce Transparency: the renderer draws its
      // own solid black layer, so a blur window behind it is a live, invisible
      // no-op — the same suppression `VibeNotify.showRich` performs.
      let isOpaque = backdrop?.isOpaque ?? false
      let dim = GlobalNotificationSettings.current.screenDim
      let configuration = OverlayWindowManager.Configuration(
        presentationMode: .fullScreen,
        position: nil,
        width: nil,
        height: nil,
        backgroundColor: .clear,
        isTransparent: true,
        isMoveable: false,
        alwaysOnTop: true,
        screenBlur: !isOpaque,
        screenBlurIntensity: prefs.screenBlurIntensity.vibeNotifyIntensity,
        dismissOnScreenTap: true,
        animatePresentation: true,
        screenDim: dim,
        takesKeyFocus: true,
        backdropStyle: backdropStyle
      )
      // What the renderer should believe is behind its text.
      //
      // A painted backdrop hides the desktop outright with a surface capped at
      // `Legibility.maxSafeLuminance`; that is total coverage, so it reads as 1
      // and the renderer draws no local scrim — the same conclusion it reaches
      // over Reduce Transparency's black. Deliberately **not**
      // `backdrop?.effectiveDim`, which would be right for those two cases and
      // wrong for the third: `Legibility.backdrop` reports the blurred
      // desktop's dim as the safe 0.55 it *prescribes*, not the possibly much
      // lower one this user actually set, and handing the renderer 0.55 when
      // the screen is dimmed to 0.2 is exactly the "no scrim needed" mistake
      // this parameter exists to prevent. For that case the honest number is
      // the configuration's own, read back after its clamp so the two agree.
      let paintsOwnSurface = isOpaque || backdrop?.fill != nil
      return (configuration, paintsOwnSurface ? 1.0 : configuration.screenDim)

    case .ambient:
      let configuration = OverlayWindowManager.Configuration(
        position: windowPosition(for: prefs.position),
        width: prefs.width ?? 450,
        height: height,
        backgroundColor: .clear,
        isTransparent: true,
        isMoveable: prefs.moveable,
        alwaysOnTop: true,
        screenBlur: false,
        dismissOnScreenTap: true,
        animatePresentation: true,
        takesKeyFocus: false
      )
      // No backdrop window at all, so the renderer owns the backdrop under its
      // own text and must draw the local feathered scrim.
      return (configuration, 0)
    }
  }

  static func windowPosition(
    for position: NotificationPosition
  ) -> OverlayWindowManager.WindowPosition {
    switch position {
    case .center: return .center
    case .topLeft: return .topLeft
    case .topRight: return .topRight
    case .bottomLeft: return .bottomLeft
    case .bottomRight: return .bottomRight
    }
  }

  // MARK: - Generic Notification Methods

  @MainActor
  @discardableResult
  static func showSuccess(title: String = "Success", message: String, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.success)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: quickDismissDelay, showProgress: true)
      .show()
  }

  @MainActor
  @discardableResult
  static func showError(title: String = "Error", message: String, priority: NotificationPriority = .critical) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.error)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: defaultDismissDelay, showProgress: true)
      .show()
  }

  @MainActor
  @discardableResult
  static func showWarning(
    title: String = "Warning",
    message: String,
    priority: NotificationPriority = .normal,
    actions: [NotificationAction] = []
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    var builder = VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.warning)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: defaultDismissDelay, showProgress: true)
    for action in actions {
      builder = builder.button(StandardNotification.Button(title: action.label, style: .secondary, action: action.handler))
    }
    return builder.show()
  }

  @MainActor
  @discardableResult
  static func showInfo(
    title: String = "Info",
    message: String,
    priority: NotificationPriority = .normal,
    actions: [NotificationAction] = []
  ) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    var builder = VibeNotify.builder()
      .title(title)
      .message(message)
      .icon(.info)
      .presentationMode(.banner(edge: .top, height: compactBannerHeight))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: quickDismissDelay, showProgress: true)
    for action in actions {
      builder = builder.button(StandardNotification.Button(title: action.label, style: .secondary, action: action.handler))
    }
    return builder.show()
  }

  // MARK: - Toast Notifications (Quick Updates)

  @MainActor
  @discardableResult
  static func showToast(message: String, icon: StandardNotification.IconType = .info, priority: NotificationPriority = .normal) -> UUID? {
    guard NotificationPolicy.shared.isNotificationAllowed(priority: priority) else {
      return nil
    }

    return VibeNotify.builder()
      .message(message)
      .icon(icon)
      .presentationMode(.toast(corner: .topRight, size: CGSize(width: 300, height: 100)))
      .alwaysOnTop(true)
      .transparent(true, material: .hudWindow)
      .autoDismiss(after: 2.0, showProgress: false)
      .show()
  }

}

// MARK: - Notification Type Enum

enum NotificationType {
  case success
  case error
  case warning
  case info
  case schedule
}
