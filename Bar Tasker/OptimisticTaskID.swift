import Foundation

/// Allocates the placeholder ids used for optimistic (not-yet-server-acknowledged)
/// tasks.
///
/// Ids are negative by convention so they can never collide with a real
/// Checkvist id, and they are drawn from a monotonically decreasing sequence
/// rather than picked at random. Randomness was unsafe here for two reasons:
/// temp ids outlive the process (they are persisted in
/// `TaskRepository.pendingTaskCreates` while offline), and every lookup in the
/// task list is an id match — so a repeat silently retargets a different task's
/// replace/remove/rollback.
///
/// The cursor is persisted so ids stay unique across launches while offline
/// creates are still queued.
@MainActor
enum OptimisticTaskID {
  private static let defaultsKey = "nextOptimisticTaskId"

  private static var next: Int = {
    let stored = UserDefaults.standard.integer(forKey: defaultsKey)
    // `integer(forKey:)` returns 0 when unset; only a previously stored
    // negative cursor is meaningful.
    return stored < 0 ? stored : -1
  }()

  static func make(defaults: UserDefaults = .standard) -> Int {
    let id = next
    next = id == Int.min ? -1 : id - 1
    defaults.set(next, forKey: defaultsKey)
    return id
  }
}
