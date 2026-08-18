import PriorityCore
import SwiftUI

/// A burst of sparks along the row as it completes.
///
/// The showiest of the presets, and the only one that draws anything the row
/// couldn't express by itself — hence `makeRowAccent`. Particles are drawn in a
/// single `Canvas` rather than as a stack of views: at twenty-odd sparks the
/// view-per-particle version costs more in layout than the effect is worth.
@MainActor
final class SparkCelebrationPlugin: CompletionCelebrationPlugin {
  let pluginIdentifier = "native.celebration.spark"
  let displayName = "Spark"
  let pluginDescription = "Sparks scatter along the row as it completes."
  let celebrationIconSystemName = "sparkles"
  let rowTreatment = CelebrationRowTreatment.spark

  private static let leadIn: TimeInterval = 0.02
  private static let burst: TimeInterval = 0.16

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
      try await Task.sleep(for: .seconds(step(Self.leadIn)))
      withAnimation(.spring(response: 0.24, dampingFraction: 0.5)) {
        stage.setCompleting(event.kind)
      }
      try await Task.sleep(for: .seconds(step(Self.burst)))
    } catch {
      withAnimation { stage.setCompleting(nil) }
      return false
    }
    withAnimation { stage.setCompleting(nil) }
    return true
  }

  func makeRowAccent(for kind: CompletionKind) -> AnyView? {
    AnyView(SparkBurst(seed: kind.sparkSeed, count: 18))
  }

  func makeFlourish(_ event: CompletionEvent) -> AnyView? {
    guard event.milestone.earnsFlourish else { return nil }
    // A milestone earns a denser burst across the panel rather than a different
    // idiom — same sparks, more of them, more room.
    return AnyView(SparkBurst(seed: event.ordinal, count: 48).padding(.vertical, 24))
  }
}

extension CompletionKind {
  /// A stable per-row seed, so two rows completing together don't scatter their
  /// sparks identically. `Math.random` is deliberately avoided — the pattern
  /// should be reproducible for a given row.
  fileprivate var sparkSeed: Int {
    switch self {
    case .task(let id): return id
    case .daily(let id): return abs(id.hashValue % 9973)
    }
  }
}

/// Sparks thrown outward from the row's centre line, drawn in one `Canvas`.
///
/// The positions come from a small deterministic hash rather than
/// `Double.random`, so a given row always bursts the same way — a re-render
/// mid-animation would otherwise reshuffle every particle.
private struct SparkBurst: View {
  let seed: Int
  let count: Int

  @Environment(AppCoordinator.self) private var manager
  @State private var progress: Double = 0

  var body: some View {
    let tint = manager.preferences.themeColor(for: .success)
    let accent = manager.preferences.themeAccentColor

    Canvas { context, size in
      guard progress > 0 else { return }
      for index in 0..<count {
        let noise = Self.noise(seed: seed, index: index)
        // Spread along the row, biased away from the very edges.
        let originX = size.width * (0.08 + 0.84 * noise.0)
        let originY = size.height * 0.5
        // Mostly sideways, a little vertical, so it reads as a scatter along
        // the line rather than a firework.
        let driftX = (noise.1 - 0.5) * size.width * 0.22
        let driftY = (noise.2 - 0.5) * size.height * 1.6

        let eased = 1 - pow(1 - progress, 2)
        let x = originX + driftX * eased
        let y = originY + driftY * eased
        let radius = (0.9 + noise.3 * 1.3) * (1 - progress)
        guard radius > 0.05 else { continue }

        let rect = CGRect(
          x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        let color = noise.3 > 0.7 ? accent : tint
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(1 - progress)))
      }
    }
    .onAppear {
      withAnimation(.easeOut(duration: CompletionMilestonePolicy.flourishBudget)) {
        progress = 1
      }
    }
  }

  /// Four decorrelated values in the range 0...1 from an integer pair.
  ///
  /// A hand-rolled hash rather than `SystemRandomNumberGenerator` because the
  /// result must be identical every time the view re-evaluates its body.
  private static func noise(seed: Int, index: Int) -> (Double, Double, Double, Double) {
    func mix(_ salt: Int) -> Double {
      var value = UInt64(bitPattern: Int64(seed &* 73_856_093 ^ index &* 19_349_663 ^ salt))
      value ^= value >> 33
      value = value &* 0xff51_afd7_ed55_8ccd
      value ^= value >> 33
      return Double(value % 10_000) / 10_000
    }
    return (mix(1), mix(2), mix(3), mix(4))
  }
}
