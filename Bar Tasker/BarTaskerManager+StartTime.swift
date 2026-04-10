import Foundation

extension BarTaskerManager {

  // MARK: - Convenience accessors (delegate to StartDateManager)

  func startDateString(for task: CheckvistTask) -> String? {
    startDates.startDateString(for: task)
  }

  func startDate(for task: CheckvistTask) -> Date? {
    startDates.startDate(for: task)
  }

  @MainActor func setStartDate(for task: CheckvistTask, rawInput: String) {
    startDates.setStartDate(for: task, rawInput: rawInput) { [self] input in
      resolveDueDateWithConfig(input)
    }
  }

  @MainActor func clearStartDate(for task: CheckvistTask) {
    startDates.clearStartDate(for: task)
  }

  func startDateLabel(for task: CheckvistTask) -> String? {
    startDates.startDateLabel(for: task)
  }

  func startDateIsInFuture(for task: CheckvistTask) -> Bool {
    startDates.startDateIsInFuture(for: task)
  }
}
