import Foundation
import Observation

@MainActor
@Observable final class FocusSessionManager {
  struct ActiveSession {
    let taskId: Int
    let durationSeconds: Int
    let baselineElapsed: TimeInterval
  }

  static let minDurationMinutes = 1
  static let maxDurationMinutes = 240
  static let defaultDurationMinutes = 25

  @ObservationIgnored private let preferencesStore: PreferencesStore

  /// Task ID for which the focus-start prompt is showing.
  var promptTaskId: Int? = nil

  /// Active focus session (nil when no session is running).
  var session: ActiveSession? = nil

  /// User-configurable focus duration in minutes. Persisted.
  var durationMinutes: Int {
    didSet {
      let clamped = min(Self.maxDurationMinutes, max(Self.minDurationMinutes, durationMinutes))
      if clamped != durationMinutes {
        durationMinutes = clamped
        return
      }
      preferencesStore.set(durationMinutes, for: .focusDurationMinutes)
    }
  }

  @ObservationIgnored var onCacheRelevantChange: (() -> Void)?

  init(preferencesStore: PreferencesStore) {
    self.preferencesStore = preferencesStore
    let stored = preferencesStore.int(.focusDurationMinutes, default: Self.defaultDurationMinutes)
    self.durationMinutes = min(
      Self.maxDurationMinutes, max(Self.minDurationMinutes, stored)
    )
  }

  func presentPrompt(forTaskId taskId: Int) {
    session = nil
    promptTaskId = taskId
    onCacheRelevantChange?()
  }

  func dismissPrompt() {
    promptTaskId = nil
    onCacheRelevantChange?()
  }

  func startSession(baselineElapsed: TimeInterval) {
    guard let taskId = promptTaskId else { return }
    session = ActiveSession(
      taskId: taskId,
      durationSeconds: durationMinutes * 60,
      baselineElapsed: baselineElapsed
    )
    promptTaskId = nil
    onCacheRelevantChange?()
  }

  func cancelSession() {
    session = nil
    promptTaskId = nil
    onCacheRelevantChange?()
  }

  func adjustDuration(by delta: Int) {
    durationMinutes += delta
  }

  /// Drop prompt/session if their task no longer exists or has been completed.
  func clampForTasks<S: Sequence>(_ tasks: S) where S.Element == CheckvistTask {
    let openIds = Set(tasks.lazy.filter { $0.status == 0 }.map { $0.id })
    if let promptId = promptTaskId, !openIds.contains(promptId) {
      promptTaskId = nil
    }
    if let sessionId = session?.taskId, !openIds.contains(sessionId) {
      session = nil
    }
  }
}
