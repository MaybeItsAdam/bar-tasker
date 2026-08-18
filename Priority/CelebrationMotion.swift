import PriorityCore
import SwiftUI

/// The curves a completion animates on, in one place.
///
/// Every surface that renders a completing row — the task list, the Daily
/// checklist — used to spell its own `.spring(response: 0.3, dampingFraction:
/// 0.5)` inline. Two problems came out of that. The obvious one is drift: the
/// two rows could disagree about how a completion feels. The subtle one is that
/// a curve written at the call site tends to be written *once*, on the one
/// modifier the author was thinking about, leaving the row's tint and its
/// leading bar to snap while its scale springs.
///
/// The timings are deliberately shorter than the ones they replace.
/// `CompletionMilestonePolicy.inlineBudget` caps the whole blocking sequence at
/// 220ms, and a 300ms spring inside a 210ms window is a spring that is
/// interrupted in both directions and never resolves — which is what made the
/// effect read as a twitch rather than as a motion.
enum CelebrationMotion {

  /// The row itself: scale, tint, leading bar. Damped fairly high, because this
  /// is a large surface and a wobbly one draws attention to the animation
  /// instead of to what it means.
  static func row(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.24, reduceMotion), dampingFraction: 0.72)
  }

  /// The status glyph. Much looser — a small shape is where an overshoot reads
  /// as confidence rather than as slop, and this is the moment the completion
  /// is actually *felt*.
  static func icon(reduceMotion: Bool) -> Animation {
    .spring(response: scaled(0.26, reduceMotion), dampingFraction: 0.5)
  }

  /// The strikethrough sweeping across the title. Linear-ish rather than
  /// springy: a line being drawn should not overshoot the end of the word and
  /// come back.
  static func strike(reduceMotion: Bool) -> Animation {
    .easeOut(duration: scaled(0.14, reduceMotion))
  }

  /// Reduced motion collapses durations rather than removing the animation, so
  /// a row still resolves between states instead of teleporting. Same rule, and
  /// the same reasoning, as `CompletionMilestonePolicy.durationScale`, which is
  /// where the factor comes from.
  private static func scaled(_ duration: TimeInterval, _ reduceMotion: Bool) -> TimeInterval {
    duration * CompletionMilestonePolicy.durationScale(reduceMotion: reduceMotion)
  }
}
