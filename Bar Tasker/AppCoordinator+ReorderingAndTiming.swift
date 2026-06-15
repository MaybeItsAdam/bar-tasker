import Foundation
import OSLog

/// Mixed grab-bag at this point in the refactor:
/// - **Forwarders to `SyncService`** for the reorder / move / indent surface.
/// - **Helpers retained on `AppCoordinator`** because other services
///   (`TaskMutationService` in particular) still call them through the
///   coordinator: `subtreeBlockRange`, the timer/cache roll-up accessors, the
///   command-input executor, and the date-resolver helpers.
extension AppCoordinator {
  // MARK: - Subtree helper (still needed by TaskMutationService through self)

  func subtreeBlockRange(for taskId: Int, in flatTasks: [CheckvistTask]) -> Range<Int>? {
    guard let start = flatTasks.firstIndex(where: { $0.id == taskId }) else { return nil }

    var end = start + 1
    while end < flatTasks.count {
      let candidate = flatTasks[end]
      if isDescendant(candidate, of: taskId) {
        end += 1
      } else {
        break
      }
    }
    return start..<end
  }

  // MARK: - Command + date helpers

  @MainActor func executeCommandInput(_ input: String) async {
    let parsed = CommandEngine.parse(input)
    logger.log("Executing command: \(input, privacy: .public)")
    await commandExecutor.execute(parsed: parsed)
    if case .unknown(let raw) = parsed {
      logger.error("Unknown command: \(raw, privacy: .public)")
    }
  }

  static func resolveDueDate(_ input: String) -> String {
    CommandEngine.resolveDueDate(input)
  }

  func resolveDueDateWithConfig(_ input: String) -> String {
    let config = BarTaskerDateParsingConfig(
      morningHour: preferences.namedTimeMorningHour,
      afternoonHour: preferences.namedTimeAfternoonHour,
      eveningHour: preferences.namedTimeEveningHour,
      eodHour: preferences.namedTimeEodHour
    )
    return CommandEngine.resolveDueDate(input, config: config)
  }

  // MARK: - Timer / cache roll-up accessors

  func totalElapsed(forTaskId taskId: Int) -> TimeInterval {
    rolledUpElapsedByTaskId()[taskId] ?? 0
  }

  func totalElapsed(for task: CheckvistTask) -> TimeInterval {
    totalElapsed(forTaskId: task.id)
  }

  func childCountByTaskId() -> [Int: Int] {
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.childCount
  }

  func rolledUpElapsedByTaskId() -> [Int: TimeInterval] {
    // Touch the observable dictionary so SwiftUI re-renders on per-second
    // ticks. Without this, callers only read the @ObservationIgnored cache
    // and never establish a dependency on `timer.timerByTaskId`.
    _ = timer.timerByTaskId
    taskListViewModel.ensureVisibleTasksCacheValid()
    return taskListViewModel.cache.rolledUpElapsed
  }
}
