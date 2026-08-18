import AppKit
import SwiftUI
import VibeNotify

/// The global notification appearance editor — the one place the user sets how
/// notifications look, instead of repeating it on every action.
///
/// Every control here writes `GlobalNotificationSettings`, which is the bottom
/// of the resolution stack: an action that says nothing about its appearance
/// gets exactly this, and an action that overrides one key keeps that key and
/// inherits the rest. The per-action editor's Advanced disclosure is the other
/// half of the story.
///
/// ## Why this looks different from the rest of Settings
///
/// The layout here — a right-aligned label column, controls to their right,
/// grouped boxes, segmented controls for small choices, captions demoted to
/// small secondary text and used sparingly — is the macOS settings idiom, and
/// it is deliberately *not* what the neighbouring sections in `SettingsDetail`
/// do. Those stack `Toggle`s full-width with a body-size line and a caption
/// line inside each label, one flat run down the pane, which is a form dump:
/// every section carries the same visual weight, the prose outweighs the
/// controls, and the eye has nowhere to rest. This section is the largest one
/// in the pane and had the worst of it (five full-width rectangles for a
/// five-way choice; sliders bleeding the full width with their readouts
/// stranded at the far edge), so the better pattern is set here rather than
/// invented a third time somewhere else. `SettingsGroup` / `SettingsRow` /
/// `SliderRow` below are written to be lifted into the other sections
/// unchanged when someone does that work.
struct NotificationAppearanceSettingsView: View {
  @EnvironmentObject private var appState: AppState

  @State private var settings: GlobalNotificationSettings = .current
  @State private var previewSent = false
  /// Which simulated desktop the *preview* paints behind itself. Purely local
  /// `@State`: it is never written to `settings`, never reaches a `notify.*`
  /// key, and is read in exactly one place (`showPreview`). See
  /// `PreviewDesktop`.
  @State private var previewDesktop: PreviewDesktop = .none
  /// Coalesces a slider drag into one profile write. The local mirror is
  /// updated on every change (so the preview button is always honest); only the
  /// gRPC round trip waits.
  @State private var syncTask: Task<Void, Never>?

  @StateObject private var previewDesktopWindow = PreviewDesktopController()

  private static let profileSyncDelay: Duration = .milliseconds(700)

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Appearance")
          .font(.headline)
        Text("Used by every notification unless the action that fires it overrides it.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      layoutGroup
      backdropGroup
      behaviorGroup
      breakCountdownGroup
      previewGroup
    }
    .onChange(of: settings) { _, newValue in
      scheduleSave(newValue)
    }
    .onAppear {
      settings = .current
    }
    // Scenery must never outlive the screen that put it up. Leaving this
    // section — or closing the window — while a simulated desktop is painted
    // would otherwise strand a full-screen opaque window with no control left
    // on screen to take it down.
    .onDisappear {
      previewDesktopWindow.hide()
    }
  }

  // MARK: - Layout (position and size)

  private var layoutGroup: some View {
    SettingsGroup("Layout") {
      SettingsRow(
        "Position",
        caption: "Applies to floating alerts. A full-screen alert covers the display."
      ) {
        Picker("Position", selection: $settings.position) {
          ForEach(NotificationPosition.allCases, id: \.self) { position in
            Image(systemName: position.iconName)
              .accessibilityLabel(position.displayName)
              .tag(position)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
      }

      SliderRow(
        "Width",
        value: Binding(get: { Double(settings.width) }, set: { settings.width = CGFloat($0) }),
        range: 300...800,
        step: 50,
        readout: "\(Int(settings.width))")

      SliderRow(
        "Height",
        value: Binding(get: { Double(settings.height) }, set: { settings.height = CGFloat($0) }),
        range: 150...500,
        step: 25,
        readout: "\(Int(settings.height))",
        caption: "A floor — an alert grows past it when its content needs the room.")
    }
  }

  // MARK: - Backdrop

  /// Blur, backdrop and dim in one box, because they are one decision: what is
  /// behind a full-screen alert. The dim row disables itself for a painted
  /// backdrop rather than disappearing — a control that vanishes reads as a
  /// bug, and the caption says why it is inert.
  private var backdropGroup: some View {
    SettingsGroup("Full-Screen Alerts") {
      SettingsRow(
        "Take over the screen",
        caption: "Turns notifications into full-screen interruptions instead of floating alerts."
      ) {
        Toggle("", isOn: $settings.screenBlurEnabled)
          .toggleStyle(.switch)
          .labelsHidden()
      }

      SettingsRow(
        "Behind the alert",
        caption: settings.backdropStyle.summary
      ) {
        HStack(spacing: 8) {
          Picker("Behind the alert", selection: $settings.backdropStyle) {
            ForEach(BackdropStyle.allCases) { style in
              Text(style.displayName).tag(style)
            }
          }
          .labelsHidden()
          .frame(width: 190)
          // After the picker, not before it: left of a pop-up button a small
          // filled rounded rect reads as a disabled text field. Reading order
          // choice-then-sample makes it a sample.
          BackdropSwatch(style: settings.backdropStyle)
        }
      }

      // Disabled rather than removed for a painted backdrop, like the dim row
      // below: the setting still exists and still applies the moment the user
      // goes back to the blurred desktop, and a control that vanishes reads as
      // something having gone wrong.
      SettingsRow("Blur") {
        Picker("Blur", selection: $settings.screenBlurIntensity) {
          ForEach(BlurIntensity.allCases, id: \.self) { intensity in
            Text(intensity.displayName).tag(intensity)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
      }
      .disabled(settings.backdropStyle != .blurredDesktop)

      SliderRow(
        "Dim",
        value: $settings.screenDim,
        range: GlobalNotificationSettings.screenDimRange,
        step: 0.05,
        readout: "\(Int((settings.screenDim * 100).rounded()))%",
        caption: dimCaption
      )
      .disabled(settings.backdropStyle != .blurredDesktop)

      if settings.backdropStyle == .blurredDesktop,
        settings.screenDim < GlobalNotificationSettings.wcagSafeScreenDim
      {
        SettingsRow("") {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text("Below the readable minimum — alerts fall back to shading their own text.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("Fix") {
              settings.screenDim = GlobalNotificationSettings.wcagSafeScreenDim
            }
            .controlSize(.small)
          }
        }
      }
    }
  }

  private var dimCaption: String {
    guard settings.backdropStyle == .blurredDesktop else {
      return "A painted backdrop hides the desktop, so there is no light left to dim."
    }
    let safe = Int((GlobalNotificationSettings.wcagSafeScreenDim * 100).rounded())
    return "At \(safe)% white text clears WCAG AA over any desktop."
  }

  // MARK: - Behavior

  private var behaviorGroup: some View {
    SettingsGroup("Behavior") {
      SettingsRow("Draggable", caption: "Move a floating alert aside instead of dismissing it.") {
        Toggle("", isOn: $settings.moveable)
          .toggleStyle(.switch)
          .labelsHidden()
      }

      SliderRow(
        "Auto-dismiss",
        value: $settings.autoDismissAfter,
        range: 5...60,
        step: 5,
        readout: "\(Int(settings.autoDismissAfter))s",
        caption: "Ignored while a break countdown is running.")
    }
  }

  // MARK: - Break countdown

  private var breakCountdownGroup: some View {
    SettingsGroup("Break Countdown") {
      SettingsRow("Unit label") {
        TextField("seconds", text: $settings.breakUnitLabel)
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
      }

      SettingsRow(
        "Completion label",
        caption: "Wording for the big ring an action shows when it sets a break duration."
      ) {
        TextField("Break complete", text: $settings.breakCompletionLabel)
          .textFieldStyle(.roundedBorder)
          .frame(width: 200)
      }
    }
  }

  // MARK: - Preview

  private var previewGroup: some View {
    SettingsGroup("Preview") {
      SettingsRow(
        "",
        caption: "Fires through the same path a real schedule notification takes."
      ) {
        HStack(spacing: 10) {
          Button {
            showPreview()
          } label: {
            Label("Preview", systemImage: "eye")
          }
          .buttonStyle(.borderedProminent)

          Button("Reset to Defaults") {
            settings = .fallback
          }

          if previewSent {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .help("Preview sent")
              .transition(.opacity)
          }
        }
      }

      SettingsRow(
        "Test against",
        caption:
          "A fake desktop painted behind the preview only, to judge legibility without rearranging windows. Real notifications never paint it."
      ) {
        Picker("Test against", selection: $previewDesktop) {
          ForEach(PreviewDesktop.allCases) { desktop in
            Text(desktop.displayName).tag(desktop)
          }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 190)
      }
    }
  }

  // MARK: - Actions

  /// The preview goes through `VibeNotifyConfig.showScheduleNotification` —
  /// the same funnel the three per-action preview buttons and every delivered
  /// schedule alert use. A preview rendered any other way would teach a layout
  /// the user is never going to get.
  ///
  /// The simulated desktop is scenery put up *around* that call and taken down
  /// when the overlay it was staged for ends. It is deliberately not a
  /// parameter of the funnel: nothing about `showScheduleNotification`,
  /// `NotificationPreferences` or the persisted `notify.*` keys knows this
  /// exists, so there is no path by which a real alert could paint one — the
  /// only way to see it is to press this button with this picker set.
  private func showPreview() {
    // Flush before previewing: the funnel reads the persisted screen dim and
    // backdrop, and an in-flight slider edit that has not landed yet would
    // preview the old one.
    settings.persistLocally()

    previewDesktopWindow.show(previewDesktop)

    let id = VibeNotifyConfig.showScheduleNotification(
      scheduleName: "Preview Notification",
      routineName: "Global notification settings",
      scheduledTime: Date(),
      notes: nil,
      preferences: settings.basePreferences()
    )

    if let id {
      // Deterministic teardown rather than a timer: the preview can end by
      // ESC, a click, a button or its own auto-dismiss, and every one of those
      // has to take the scenery with it.
      OverlayWindowManager.shared.addEndHandler(id: id) { _ in
        previewDesktopWindow.hide()
      }
    } else {
      // `showScheduleNotification` returns nil when a `NotificationPolicy`
      // guard refuses the alert. No overlay means no end event, so the scenery
      // would otherwise stay up forever with nothing behind it.
      previewDesktopWindow.hide()
    }

    withAnimation { previewSent = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { previewSent = false }
    }
  }

  private func scheduleSave(_ newValue: GlobalNotificationSettings) {
    newValue.persistLocally()
    syncTask?.cancel()
    syncTask = Task {
      try? await Task.sleep(for: Self.profileSyncDelay)
      guard !Task.isCancelled else { return }
      appState.saveGlobalNotificationSettings(newValue)
    }
  }
}

// MARK: - Settings chrome

/// A titled, bordered group of rows — the container macOS settings panes put
/// related controls in, and the thing this screen had none of.
struct SettingsGroup<Content: View>: View {
  private let title: String
  private let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color(NSColor.controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
      )
    }
  }
}

/// One row: label in a fixed right-aligned column, control to its right, and an
/// optional caption *under the control* at caption size.
///
/// The fixed column is what produces the vertical rhythm macOS settings have
/// and this screen did not: every control in the pane starts at the same x, so
/// the eye reads a column of controls rather than a wall of stacked blocks. An
/// empty `label` keeps a row aligned to that column without repeating a title
/// the control already carries.
struct SettingsRow<Control: View>: View {
  private let label: String
  private let caption: String?
  private let control: Control

  static var labelColumnWidth: CGFloat { 132 }

  init(_ label: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
    self.label = label
    self.caption = caption
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .frame(width: Self.labelColumnWidth, alignment: .trailing)

      VStack(alignment: .leading, spacing: 4) {
        control
        if let caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// A `SettingsRow` whose control is a slider with its readout **immediately to
/// its right**, not at the far edge of the pane.
///
/// That is the whole point of the fixed slider width: a full-bleed slider puts
/// the number a screen away from the handle it describes, so reading a value
/// means a saccade across the entire window.
struct SliderRow: View {
  private let label: String
  @Binding private var value: Double
  private let range: ClosedRange<Double>
  private let step: Double
  private let readout: String
  private let caption: String?

  init(
    _ label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    readout: String,
    caption: String? = nil
  ) {
    self.label = label
    self._value = value
    self.range = range
    self.step = step
    self.readout = readout
    self.caption = caption
  }

  var body: some View {
    SettingsRow(label, caption: caption) {
      HStack(spacing: 8) {
        Slider(value: $value, in: range, step: step)
          .frame(width: 200)
        Text(readout)
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 42, alignment: .leading)
      }
    }
  }
}

/// The chosen backdrop, drawn. A name alone ("Deep Sea") does not tell anyone
/// what they are about to stare at for twenty seconds.
struct BackdropSwatch: View {
  let style: BackdropStyle

  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(fill)
      .frame(width: 34, height: 20)
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
      )
  }

  private var fill: AnyShapeStyle {
    guard let fill = style.fill else {
      // The blurred desktop has no colour of its own to show — it is whatever
      // the desktop happens to be — so this stands for "dimmed desktop"
      // rather than pretending to a specific tone.
      return AnyShapeStyle(
        LinearGradient(
          colors: [Color(white: 0.30), Color(white: 0.12)],
          startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    return AnyShapeStyle(
      LinearGradient(
        colors: fill.stops.map(\.color),
        startPoint: .topLeading,
        endPoint: .bottomTrailing))
  }
}

// MARK: - Preview desktop (a testing affordance)

/// A fake desktop painted behind a *preview* alert, so legibility can be judged
/// against a hostile surface without rearranging real windows.
///
/// Ported from the library's demo harness (`VibeNotifyDemo/Sources/Backdrop.swift`),
/// including its option set, because those options were chosen for a reason:
/// `.splitBlackWhite` is the desktop that produced the original bug — a dark
/// terminal on one half, a white browser on the other, with the title straddling
/// the seam — and the rest stress the same invariant from other angles.
///
/// **This is not a setting.** It lives in view `@State`, it is not part of
/// `GlobalNotificationSettings`, it has no `notify.*` key, and it is read at
/// exactly one call site. A delivered notification cannot reach it.
enum PreviewDesktop: String, CaseIterable, Identifiable {
  case none
  case splitBlackWhite
  case white
  case midGrey
  case saturatedGradient
  case busyPattern

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: return "Nothing (real desktop)"
    case .splitBlackWhite: return "Split black / white"
    case .white: return "Solid white"
    case .midGrey: return "Mid-grey field"
    case .saturatedGradient: return "Saturated gradient"
    case .busyPattern: return "Busy pattern"
    }
  }
}

/// Paints a `PreviewDesktop` full-bleed.
private struct PreviewDesktopView: View {
  let desktop: PreviewDesktop

  var body: some View {
    switch desktop {
    case .none:
      Color.clear
    case .splitBlackWhite:
      HStack(spacing: 0) {
        Color.black
        Color.white
      }
    case .white:
      Color.white
    case .midGrey:
      Color(white: 0.5)
    case .saturatedGradient:
      LinearGradient(
        colors: [
          Color(red: 0.98, green: 0.42, blue: 0.16),
          Color(red: 0.78, green: 0.09, blue: 0.62),
          Color(red: 0.06, green: 0.42, blue: 0.86),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)
    case .busyPattern:
      Canvas { context, size in
        let cell: CGFloat = 8
        var x: CGFloat = 0
        var row = 0
        while x < size.width {
          var y: CGFloat = 0
          var col = 0
          while y < size.height {
            let dark = (row + col).isMultiple(of: 2)
            context.fill(
              Path(CGRect(x: x, y: y, width: cell, height: cell)),
              with: .color(dark ? .black : .white))
            y += cell
            col += 1
          }
          x += cell
          row += 1
        }
      }
    }
  }
}

/// Owns the single borderless window a `PreviewDesktop` is painted into.
///
/// **Window level.** The point of this window is to stand in for the user's
/// real desktop, so it has to render *above* the ordinary windows that are
/// already open — one step above `NSWindow.Level.normal`. That is still well
/// below the alert's own windows (`.floating` for the content window,
/// `.floating - 1` for the backdrop window), so the stacking a user sees is:
/// real windows, this fake desktop, the alert's backdrop, the alert. It does
/// cover this Settings window while it is up, which is correct — a full-screen
/// preview covers it anyway, and it comes down with the alert.
@MainActor
final class PreviewDesktopController: ObservableObject {
  private var window: NSWindow?

  func show(_ desktop: PreviewDesktop) {
    guard desktop != .none, let screen = NSScreen.main else {
      hide()
      return
    }

    let win =
      window
      ?? {
        let created = NSWindow(
          contentRect: screen.frame,
          styleMask: [.borderless],
          backing: .buffered,
          defer: false,
          screen: screen)
        created.isOpaque = true
        created.hasShadow = false
        created.isReleasedWhenClosed = false
        // Scenery, not UI: never intercepts a click, so anything it covers
        // stays reachable.
        created.ignoresMouseEvents = true
        created.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window = created
        return created
      }()

    win.setFrame(screen.frame, display: true)
    win.contentView = NSHostingView(rootView: PreviewDesktopView(desktop: desktop))
    win.orderFrontRegardless()
  }

  func hide() {
    window?.orderOut(nil)
  }
}
