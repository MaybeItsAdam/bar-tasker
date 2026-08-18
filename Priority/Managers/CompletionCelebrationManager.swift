import AppKit
import Observation
import PriorityCore
import SwiftUI

/// Owns which completion celebration is active, runs it, and holds the
/// post-mutation flourish for the popover overlay to render.
///
/// Modelled on `DailyLogManager`: a thin `@Observable` that keeps the plugin
/// reference, write-throughs the user's choice, and bumps state SwiftUI can
/// watch. Unlike the other plugin capabilities, the registry is retained rather
/// than read once at launch, because the user can switch presets at runtime.
///
/// It is also the `CelebrationStage` presets talk to, which is what keeps them
/// from needing to know that a completing *task* is flagged on
/// `QuickEntryManager` while a completing *daily* is flagged here.
@MainActor
@Observable final class CompletionCelebrationManager: CelebrationStage {
  @ObservationIgnored private let preferencesStore: PreferencesStore
  @ObservationIgnored private let registry: PluginRegistry
  @ObservationIgnored private weak var quickEntry: QuickEntryManager?

  /// Fallback when nothing is stored, or when a stored identifier no longer
  /// resolves (a preset removed between releases).
  static let defaultCelebrationIdentifier = "native.celebration.strike"

  /// Mirrors `QuickEntryManager.completingTaskId` for the Daily view, which
  /// keys its rows by `String` and lives outside the task list entirely.
  private(set) var completingDailyId: String?

  /// The flourish currently on screen, if any. The identity is carried
  /// separately so two consecutive milestones re-trigger `onAppear` instead of
  /// SwiftUI reusing the first one's view.
  private(set) var activeFlourish: (id: UUID, view: AnyView)?

  var availableCelebrations: [any CompletionCelebrationPlugin] {
    registry.celebrationPlugins
  }

  /// Mirrors the registry's active identifier as `@Observable` state.
  ///
  /// The registry itself is `@ObservationIgnored` — it is a plain lookup table,
  /// and every other capability resolves out of it exactly once at launch. This
  /// one is switchable from Settings, so the picker needs something to observe;
  /// reading through to the registry would leave the menu showing the old
  /// selection until some unrelated change redrew the pane.
  var activeCelebrationIdentifier: String {
    didSet {
      guard activeCelebrationIdentifier != oldValue else { return }
      guard registry.activateCelebrationPlugin(identifier: activeCelebrationIdentifier) else {
        activeCelebrationIdentifier = oldValue
        return
      }
      preferencesStore.set(activeCelebrationIdentifier, for: .completionCelebrationIdentifier)
    }
  }

  /// Resolved through the observed identifier rather than the registry's own
  /// active pointer, so that everything derived from it — `rowTreatment`, the
  /// picker's description line — re-reads when the user switches preset.
  var activeCelebration: any CompletionCelebrationPlugin {
    registry.celebrationPluginsByIdentifier[activeCelebrationIdentifier]
      ?? StrikeCelebrationPlugin()
  }

  /// Read live rather than cached: the user can flip Reduce Motion in System
  /// Settings while the app is running, and a celebration is short enough that
  /// checking per completion costs nothing.
  var prefersReducedMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  init(
    preferencesStore: PreferencesStore,
    registry: PluginRegistry,
    quickEntry: QuickEntryManager
  ) {
    self.preferencesStore = preferencesStore
    self.registry = registry
    self.quickEntry = quickEntry

    // `activateCelebrationPlugin` returns false for an unknown identifier,
    // which is exactly the "stored preset no longer exists" fallback — the
    // registry keeps whatever `nativeFirst()` activated, and we mirror that
    // rather than the dangling stored value.
    let stored = preferencesStore.string(.completionCelebrationIdentifier)
    if !stored.isEmpty {
      registry.activateCelebrationPlugin(identifier: stored)
    }
    self.activeCelebrationIdentifier =
      registry.activeCelebrationPlugin?.pluginIdentifier
      ?? Self.defaultCelebrationIdentifier
  }

  /// How a row should render while it is completing, per the active preset.
  var rowTreatment: CelebrationRowTreatment {
    activeCelebration.rowTreatment
  }

  /// Extra decoration for the completing row, if the active preset wants any.
  func rowAccent(for kind: CompletionKind) -> AnyView? {
    activeCelebration.makeRowAccent(for: kind)
  }

  // MARK: - CelebrationStage

  func setCompleting(_ kind: CompletionKind?) {
    switch kind {
    case .task(let id):
      quickEntry?.completingTaskId = id
      completingDailyId = nil
    case .daily(let id):
      completingDailyId = id
      quickEntry?.completingTaskId = nil
    case nil:
      quickEntry?.completingTaskId = nil
      completingDailyId = nil
    }
  }

  // MARK: - Running a celebration

  /// The blocking half. Returns `false` when the sequence was cancelled, which
  /// the caller must treat as "abandon the mutation".
  func runInline(_ event: CompletionEvent) async -> Bool {
    await activeCelebration.runInline(event, stage: self)
  }

  /// The non-blocking half. Call *after* the mutation has been dispatched;
  /// clears itself once the flourish budget is up.
  func presentFlourish(for event: CompletionEvent) {
    guard event.milestone.earnsFlourish,
      let view = activeCelebration.makeFlourish(event)
    else { return }

    let id = UUID()
    activeFlourish = (id, view)
    Task { @MainActor [weak self] in
      // A beat past the budget, so the flourish isn't torn out of the hierarchy
      // on the exact frame its own animation is still settling on.
      try? await Task.sleep(for: .seconds(CompletionMilestonePolicy.flourishBudget + 0.1))
      // Only clear our own flourish — a newer one may have replaced it while
      // this was sleeping.
      guard self?.activeFlourish?.id == id else { return }
      self?.activeFlourish = nil
    }
  }
}
