import PriorityCore
import SwiftUI

/// The default: a line draws through the row, the checkmark pops, the row
/// takes a wash of success tint.
///
/// The timings started as a faithful port of the sequence that shipped inline
/// in `AppCoordinator+ServiceHosts` (30ms / 100ms / 80ms) and have since been
/// retuned. Three things were wrong with the originals, all of them about the
/// *shape* of the sequence rather than its length:
///
/// - The 30ms lead-in bought nothing. It was there so the strike "doesn't race
///   the keypress", but a completion that visibly waits before acknowledging
///   you is the one thing this sequence must never do. Responding on the frame
///   the key lands is what makes it feel direct.
/// - The strike drew for 100ms and then held for 80ms. Reversed emphasis: the
///   draw is the part carrying the meaning, so it got the extra time and the
///   hold was cut to the shortest beat that still registers as a pause.
/// - The whole thing ran on a 280ms spring inside a 210ms window, so the
///   animation was interrupted in both directions and never resolved. Curves
///   now come from `CelebrationMotion`, which is sized to fit the budget.
///
/// Net: 180ms rather than 210ms, and more happens inside it.
@MainActor
final class StrikeCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.strike"
  let displayName = "Strike"
  let pluginDescription = "A line draws through the row as it completes."
  let celebrationIconSystemName = "strikethrough"
  let rowTreatment = CelebrationRowTreatment.strike

  /// Roughly how long the strikethrough takes to draw across the row. The
  /// sequence opens on it — there is no lead-in, deliberately.
  private static let strikeDraw: TimeInterval = 0.12
  /// Hold so the struck state is perceptible before the row is removed. Just
  /// long enough to register as a beat; any longer and it reads as lag.
  private static let hold: TimeInterval = 0.06

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
      withAnimation(CelebrationMotion.row(reduceMotion: reduceMotion)) {
        stage.setCompleting(event.kind)
      }
      try await Task.sleep(for: .seconds(step(Self.strikeDraw)))
      try await Task.sleep(for: .seconds(step(Self.hold)))
    } catch {
      // Cancellation means the user moved on mid-animation. Clear the row flag
      // and report it, so the caller drops the close instead of firing it late.
      withAnimation(CelebrationMotion.row(reduceMotion: reduceMotion)) {
        stage.setCompleting(nil)
      }
      return false
    }
    withAnimation(CelebrationMotion.row(reduceMotion: reduceMotion)) {
      stage.setCompleting(nil)
    }
    return true
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    return AnyView(StrikeFlourish(milestone: event.milestone))
  }
}

/// The milestone half: a rule sweeps across the panel and fades.
///
/// Deliberately restrained — it is the same gesture as the row's strikethrough,
/// scaled up to the width of the list, rather than a different idiom bolted on.
private struct StrikeFlourish: View {
  let milestone: CompletionMilestone
  @Environment(AppCoordinator.self) private var manager
  @State private var progress: Double = 0

  private var tint: Color {
    manager.preferences.themeColor(for: .success)
  }

  var body: some View {
    VStack {
      Spacer(minLength: 0)
      Rectangle()
        .fill(tint.opacity(0.55))
        .frame(height: 1.5)
        .scaleEffect(x: progress, y: 1, anchor: .leading)
        .opacity(1 - progress * 0.6)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .onAppear {
      withAnimation(.easeOut(duration: CompletionMilestonePolicy.flourishBudget)) {
        progress = 1
      }
    }
  }
}
