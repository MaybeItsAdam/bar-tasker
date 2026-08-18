import Foundation

/// What was just completed, and which row it belongs to.
///
/// Tasks and dailies are keyed differently (`Int` vs `String`) because they are
/// genuinely different things stored in different files — a task id comes from
/// Checkvist, a daily id from `dailies.json`. Folding the identifier into the
/// case keeps the two from being mixed up by a caller holding the wrong one.
public enum CompletionKind: Equatable, Sendable {
  case task(id: Int)
  case daily(id: String)

  public var isDaily: Bool {
    if case .daily = self { return true }
    return false
  }
}

/// How hard a completion should land.
///
/// Deliberately a closed set rather than a numeric "intensity": a celebration
/// plugin should be able to switch on the *occasion*, not guess what a 0.7
/// means.
public enum CompletionMilestone: Equatable, Sendable {
  /// The common case — the great majority of completions.
  case ordinary
  /// The last visible task went away, so the list is now empty.
  case listCleared
  /// A recurring intention was ticked (never fires for un-ticking).
  case dailyTicked
  /// The Nth completion of the logical day, N a multiple of `tallyInterval`.
  case dailyTally(count: Int)

  /// Whether this occasion earns a post-mutation flourish on top of the inline
  /// effect. Ordinary completions deliberately do not, so routine ticking stays
  /// as fast as it is today.
  public var earnsFlourish: Bool { self != .ordinary }
}

public struct CompletionEvent: Equatable, Sendable {
  public let kind: CompletionKind
  public let milestone: CompletionMilestone
  /// Which completion of the logical day this one is, counting from 1.
  public let ordinal: Int

  public init(
    kind: CompletionKind,
    milestone: CompletionMilestone,
    ordinal: Int
  ) {
  self.kind = kind
  self.milestone = milestone
  self.ordinal = ordinal
  }
}

/// Decides which occasion a completion is, and how long the effect may run.
///
/// Pure and headless so it can be tested without the app: the interesting part
/// is the precedence between overlapping milestones (clearing your list on your
/// tenth completion is one celebration, not two) and the duration budget, which
/// exists for a reason that is easy to forget — see `inlineBudget`.
public enum CompletionMilestonePolicy {
  /// Every Nth completion of the day earns a tally milestone.
  public static let tallyInterval = 10

  /// Ceiling for the *blocking* half of a celebration.
  ///
  /// `TaskMutationService.markCurrentTaskDone` runs the feedback before the
  /// close request and abandons the close if it returns false, so time spent
  /// here is time the mutation is delayed and the cancel window is open. The
  /// current shipped sequence is ~210ms; this is the line a preset must not
  /// cross, or completing tasks starts to feel *slower* for being prettier.
  public static let inlineBudget: TimeInterval = 0.22

  /// Ceiling for the non-blocking half, which runs after the mutation has been
  /// dispatched and therefore delays nothing.
  public static let flourishBudget: TimeInterval = 0.5

  /// Precedence: `listCleared` > `dailyTicked` > `dailyTally` > `ordinary`.
  ///
  /// Clearing the list wins because it is the rarest and most legible of the
  /// three; a tally that coincides with it is absorbed rather than queued
  /// behind it.
  ///
  /// - Parameters:
  ///   - kind: what was completed.
  ///   - remainingVisibleTaskCount: visible tasks *before* the optimistic
  ///     removal, so the last task in the list is `1`, not `0`. Ignored for
  ///     dailies, which live in a different list.
  ///   - ordinal: which completion of the day this one is, counting from 1.
  ///     Deliberately 1-based-including-this-one rather than "how many came
  ///     before": the task path asks before recording and the daily path asks
  ///     after, so a "before" count would mean something different at each call
  ///     site. Each caller converts once, here it means one thing.
  public static func milestone(
    for kind: CompletionKind,
    remainingVisibleTaskCount: Int,
    ordinal: Int
  ) -> CompletionMilestone {
    if case .task = kind, remainingVisibleTaskCount <= 1 {
      return .listCleared
    }
    if kind.isDaily {
      return .dailyTicked
    }
    if ordinal > 0, ordinal % tallyInterval == 0 {
      return .dailyTally(count: ordinal)
    }
    return .ordinary
  }

  /// Multiplier applied to every duration in a celebration.
  ///
  /// Reduced motion collapses durations rather than removing the animation
  /// outright, so a row still resolves from "striking" to "struck" instead of
  /// teleporting between the two. Not zero: a zero-length spring can leave
  /// SwiftUI without a frame to interpolate, and the haptics — which are not
  /// motion and stay on regardless — would then land against nothing.
  public static func durationScale(reduceMotion: Bool) -> Double {
    reduceMotion ? 0.25 : 1.0
  }

  /// Clamps a preset's requested duration to the budget for its phase, after
  /// applying the reduced-motion scale. A plugin cannot opt out of this.
  public static func clampedDuration(
    _ requested: TimeInterval,
    budget: TimeInterval,
    reduceMotion: Bool
  ) -> TimeInterval {
    let scaled = requested * durationScale(reduceMotion: reduceMotion)
    return max(0, min(scaled, budget))
  }
}
