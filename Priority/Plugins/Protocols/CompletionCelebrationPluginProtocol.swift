import PriorityCore
import SwiftUI

/// What a celebration is allowed to touch while it runs.
///
/// Presets drive the row through this rather than reaching for
/// `QuickEntryManager.completingTaskId` directly, because tasks and dailies
/// keep their "currently completing" flag in different places and a preset has
/// no business knowing which is which.
@MainActor
protocol CelebrationStage: AnyObject {
  /// Marks a row as mid-completion, or clears the mark when passed `nil`.
  func setCompleting(_ kind: CompletionKind?)
  /// Whether the system asked for reduced motion. Presets should route their
  /// durations through `CompletionMilestonePolicy.clampedDuration` rather than
  /// branching on this themselves.
  var prefersReducedMotion: Bool { get }
}

/// A swappable "what completing something looks like".
///
/// Motion only, by design. Haptics stay outside this protocol and fire for
/// every completion regardless of the chosen preset — they say "the app heard
/// you", which is not the same job as celebrating, and a user who turns the
/// celebration off should not also lose the confirmation.
///
/// The two members split along the one axis that matters here: `runInline` is
/// awaited *before* the close request goes out and can cancel it, whereas
/// `makeFlourish` renders after the mutation is already on its way and so can
/// afford to be showier. See `CompletionMilestonePolicy.inlineBudget`.
@MainActor
protocol CompletionCelebrationPlugin: Plugin {
  /// SF Symbol shown next to the preset's name in the picker.
  var celebrationIconSystemName: String { get }

  /// How the row renders while this preset's inline phase is running.
  ///
  /// Data rather than a view so every preset shares one row layout — see
  /// `CelebrationRowTreatment`.
  var rowTreatment: CelebrationRowTreatment { get }

  /// Optional decoration drawn over the completing row itself, for presets that
  /// need more than `rowTreatment` can express (particles, say). Distinct from
  /// `makeFlourish`, which outlives the row.
  func makeRowAccent(for kind: CompletionKind) -> AnyView?

  /// The blocking half. Must return within
  /// `CompletionMilestonePolicy.inlineBudget`.
  ///
  /// Returns `false` when the sequence was cancelled — the user navigated away
  /// or switched tasks mid-animation — in which case the caller abandons the
  /// close rather than firing it late. Implementations must let
  /// `CancellationError` out of their sleeps for this to work.
  func runInline(_ event: CompletionEvent, stage: any CelebrationStage) async -> Bool

  /// The non-blocking half, drawn in the popover's overlay layer once the
  /// mutation has been dispatched. `nil` means "nothing extra for this event",
  /// which is the right answer for `.ordinary`.
  ///
  /// It renders in the overlay rather than the row because by this point the
  /// row is gone: `applyOptimisticCompletion` has already removed the subtree.
  func makeFlourish(_ event: CompletionEvent) -> AnyView?
}

extension CompletionCelebrationPlugin {
  /// Most presets are inline-only; opting into a flourish is the exception.
  func makeFlourish(_ event: CompletionEvent) -> AnyView? { nil }
  /// Likewise: most presets say everything they need to through `rowTreatment`.
  func makeRowAccent(for kind: CompletionKind) -> AnyView? { nil }
}
