import Foundation

/// A curated thing to do during a break, ready to drop into an action's
/// `web_url`.
///
/// The list is deliberately short and hand-picked rather than a search box.
/// A break is twenty seconds long; a user who has to *choose* during it has
/// already spent the break. The choosing happens once, while authoring the
/// action, and the catalogue is what makes that choice a click.
struct BreakActivity: Identifiable, Hashable, Sendable {

  /// What the activity is for. Drives the grouping in the picker and nothing
  /// else — this is a label, not a taxonomy anything depends on.
  enum Focus: String, CaseIterable, Identifiable, Sendable {
    case eyes
    case neck
    case breathing
    case games

    var id: String { rawValue }

    var title: String {
      switch self {
      case .eyes: return "Eyes"
      case .neck: return "Neck & posture"
      case .breathing: return "Breathing"
      case .games: return "Move & follow"
      }
    }
  }

  let id: String
  /// **A description, not the video's own title.** Nothing here has been
  /// fetched, so claiming to print a publisher's title would be inventing one.
  /// Rename them freely — the id and the URL are what matter.
  let title: String
  let focus: Focus
  let url: String
  /// How long a break built around this should run. Shorts get their own
  /// length; the long routines get a slice, since the point is to do some of
  /// it, not to sit through all of it.
  let seconds: Int
  /// The web column's share of the width.
  ///
  /// Shorts are shot vertically. Given the same 64% column a landscape video
  /// gets, a vertical video is letterboxed into a tall dark frame with two
  /// black wings — so they ask for a narrow column instead and the rail takes
  /// the room back.
  let widthFraction: Double

  /// Vertical (9:16) source material.
  static let verticalWidthFraction = 0.36
  /// Landscape (16:9) source material.
  static let landscapeWidthFraction = 0.64

  // MARK: - The catalogue

  static let all: [BreakActivity] = [
    // Eyes
    BreakActivity(
      id: "eye-short-1", title: "Eye reset — short 1", focus: .eyes,
      url: "https://www.youtube.com/shorts/eG51cFCbPZs",
      seconds: 30, widthFraction: verticalWidthFraction),
    BreakActivity(
      id: "eye-short-2", title: "Eye reset — short 2", focus: .eyes,
      url: "https://www.youtube.com/shorts/91O3MT0Xp5g",
      seconds: 30, widthFraction: verticalWidthFraction),
    BreakActivity(
      id: "eye-short-3", title: "Eye reset — short 3", focus: .eyes,
      url: "https://www.youtube.com/shorts/EOiy1ubLQLA",
      seconds: 30, widthFraction: verticalWidthFraction),

    // Neck & posture
    BreakActivity(
      id: "neck-routine", title: "Neck release — from 1:08", focus: .neck,
      url: "https://youtu.be/IlCyVaoLR4Y?t=68",
      seconds: 90, widthFraction: landscapeWidthFraction),

    // Breathing
    BreakActivity(
      id: "breathing-guided", title: "Guided breathing", focus: .breathing,
      url: "https://www.youtube.com/watch?v=5DqTuWve9t8",
      seconds: 120, widthFraction: landscapeWidthFraction),
    BreakActivity(
      id: "breathing-short-1", title: "Breathing — short 1", focus: .breathing,
      url: "https://www.youtube.com/shorts/FWYkom7Enf8",
      seconds: 45, widthFraction: verticalWidthFraction),
    BreakActivity(
      id: "breathing-short-2", title: "Breathing — short 2", focus: .breathing,
      url: "https://www.youtube.com/shorts/Cq7nmTw1epA",
      seconds: 45, widthFraction: verticalWidthFraction),
    BreakActivity(
      id: "breathing-wim-hof", title: "Wim Hof breathing (11 min)", focus: .breathing,
      url: "https://www.youtube.com/watch?v=tybOi4hjZFQ",
      seconds: 300, widthFraction: landscapeWidthFraction),
    BreakActivity(
      id: "breathing-beats", title: "Breath workout beats (9 min)", focus: .breathing,
      url: "https://www.youtube.com/watch?v=sbTUwTWCzV8",
      seconds: 300, widthFraction: landscapeWidthFraction),

    // Move & follow
    BreakActivity(
      id: "game-follow-short", title: "Follow the dot — short", focus: .games,
      url: "https://www.youtube.com/shorts/uUVml5pCQxQ",
      seconds: 45, widthFraction: verticalWidthFraction),
    BreakActivity(
      id: "game-eye-exercises", title: "Eye exercise routine", focus: .games,
      url: "https://www.youtube.com/watch?v=29pQZZWdooY",
      seconds: 120, widthFraction: landscapeWidthFraction),
    BreakActivity(
      id: "game-blink-jump", title: "Blink Jump (built in)", focus: .games,
      url: "plugin:blink-jump",
      seconds: 60, widthFraction: landscapeWidthFraction),
  ]

  static func all(in focus: Focus) -> [BreakActivity] {
    all.filter { $0.focus == focus }
  }

  static func activity(withURL url: String) -> BreakActivity? {
    all.first { $0.url == url }
  }
}
