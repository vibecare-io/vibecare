import Foundation

/// What the "Add Action" menu offers, which is deliberately **not** the same
/// list as `ActionType`.
///
/// A rich notification and a plain one are the same `ActionType` on the wire —
/// `notification` — because that is what the backend schedules, what the CLI
/// prints and what every other client understands. They are different *things*
/// to author, though: one is a line of text in a corner, the other takes the
/// screen, runs a countdown and can embed a page. Burying the second one's
/// controls inside the first one's editor is what made this worth splitting.
///
/// The split therefore lives here, in the menu and the editor, and rides on a
/// parameter rather than a ninth enum value. A real enum value would mean a
/// proto change, regenerated stubs on both sides, backend mapping and executor
/// changes, and an update to every switch over `ActionType` — for a
/// distinction only the authoring UI makes. If it earns its keep, promoting it
/// later is mechanical.
struct ActionKind: Identifiable, Hashable {

  /// The parameter that records which editor an action was authored in.
  ///
  /// Only ever `"rich"`. Absent means plain, which is what every action
  /// predating this reads as — see `isRich(_:)` for why absence alone is not
  /// enough to conclude it.
  static let styleKey = "notification_style"
  static let richStyle = "rich"

  let id: String
  let title: String
  let icon: String
  let type: ActionType
  let isRich: Bool

  static let all: [ActionKind] = {
    var kinds: [ActionKind] = [
      ActionKind(
        id: "notification", title: "Send Notification", icon: "bell",
        type: .notification, isRich: false),
      ActionKind(
        id: "notification.rich", title: "Send Rich Notification", icon: "sparkles",
        type: .notification, isRich: true),
    ]
    // Everything else keeps its own name and icon, one menu entry each.
    kinds.append(
      contentsOf: ActionType.allCases
        .filter { $0 != .notification }
        .map {
          ActionKind(id: $0.rawValue, title: $0.displayName, icon: $0.iconName, type: $0, isRich: false)
        })
    return kinds
  }()

  /// The activity a brand-new rich notification starts with.
  ///
  /// The built-in one, deliberately: it is the only entry that needs no
  /// network, cannot be taken down by its publisher, and is not subject to
  /// anybody's embedding rules. A default pointing at someone else's video is
  /// a default that breaks without warning.
  static let defaultActivityID = "game-blink-jump"

  /// The parameters a newly-added action of this kind starts with.
  ///
  /// A rich notification arrives already working — countdown on, Blink Jump in
  /// the panel — rather than as an empty form that renders as a plain toast
  /// until the author finds the two controls that make it rich. The seed is
  /// only a starting point; every value is a control on the sheet.
  func seedParameters() -> [String: String] {
    guard type == .notification else { return [:] }
    var seed = ["title": "", "body": ""]
    guard isRich else { return seed }

    seed[Self.styleKey] = Self.richStyle
    if let activity = BreakActivity.all.first(where: { $0.id == Self.defaultActivityID }) {
      seed["web_url"] = activity.url
      seed["web_width"] = String(format: "%.2f", activity.widthFraction)
      seed["task_timer_seconds"] = String(activity.seconds)
    }
    return seed
  }

  /// Whether an existing action should open in the rich editor.
  ///
  /// The marker is checked first, but **cannot be the only test**. Actions
  /// authored before this split exists — including every one written by the
  /// MCP server, the CLI, or a routine template — carry a break countdown or a
  /// web panel and no marker at all. Deciding purely on the marker would open
  /// those in the plain editor, which has no controls for either, so the
  /// author would see an action whose most important settings had silently
  /// vanished and whose next save would drop them.
  ///
  /// So the rich *features* also count as evidence. An action that has one is
  /// a rich action whatever it was authored in.
  static func isRich(_ parameters: [String: String]) -> Bool {
    if parameters[styleKey] == richStyle { return true }
    return parameters["task_timer_seconds"] != nil || parameters["web_url"] != nil
  }

  /// What to call an action in a list, where the plain `ActionType.displayName`
  /// would call a rich notification and a plain one the same thing — the exact
  /// confusion this split exists to remove.
  static func displayName(for type: ActionType, parameters: [String: String]) -> String {
    guard type == .notification, isRich(parameters) else { return type.displayName }
    return "Send Rich Notification"
  }

  static func iconName(for type: ActionType, parameters: [String: String]) -> String {
    guard type == .notification, isRich(parameters) else { return type.iconName }
    return "sparkles"
  }
}
