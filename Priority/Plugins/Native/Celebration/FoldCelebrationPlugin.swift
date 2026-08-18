import PriorityCore
import SwiftUI

/// The row folds shut and fades rather than being struck through.
///
/// Where `Strike` annotates the row and then removes it, this makes the removal
/// itself the effect — the gap closing is what tells you the task is gone. It
/// suits long lists, where a line drawn through row six is easy to miss but the
/// list settling upward is not.
@MainActor
final class FoldCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.fold"
  let displayName = "Fold"
  let pluginDescription = "The row folds away and the list closes over it."
  let celebrationIconSystemName = "arrow.down.right.and.arrow.up.left"
  let rowTreatment = CelebrationRowTreatment.fold

  /// Longer than `Strike`'s lead-in: a collapse needs a beat at full height to
  /// read as a fold rather than a jump cut. Still inside the inline budget.
  private static let settle: TimeInterval = 0.04
  private static let collapse: TimeInterval = 0.13

  func runInline(_ event: CompletionEvent, stage: any CelebrationStage) async -> Bool {
    let reduceMotion = stage.prefersReducedMotion
    func step(_ requested: TimeInterval) -> TimeInterval {
      CompletionMilestonePolicy.clampedDuration(
        requested,
        budget: CompletionMilestonePolicy.inlineBudget,
        reduceMotion: reduceMotion
      )
    }

    do {
      try await Task.sleep(for: .seconds(step(Self.settle)))
      withAnimation(.easeIn(duration: step(Self.collapse))) {
        stage.setCompleting(event.kind)
      }
      try await Task.sleep(for: .seconds(step(Self.collapse)))
    } catch {
      withAnimation { stage.setCompleting(nil) }
      return false
    }
    withAnimation { stage.setCompleting(nil) }
    return true
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    return AnyView(FoldFlourish())
  }
}

/// A soft wash that settles down the panel, echoing the row's collapse at the
/// scale of the whole list.
private struct FoldFlourish: View {
  @Environment(AppCoordinator.self) private var manager
  @State private var settled = false

  var body: some View {
    let tint = manager.preferences.themeColor(for: .success)
    LinearGradient(
      colors: [tint.opacity(settled ? 0 : 0.18), .clear],
      startPoint: .top,
      endPoint: .bottom
    )
    .opacity(settled ? 0 : 1)
    .onAppear {
      withAnimation(.easeOut(duration: CompletionMilestonePolicy.flourishBudget)) {
        settled = true
      }
    }
  }
}
