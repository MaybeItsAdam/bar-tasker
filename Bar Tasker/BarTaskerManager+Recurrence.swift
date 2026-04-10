import Foundation

extension BarTaskerManager {

  // MARK: - Convenience accessors (delegate to RecurrenceManager)

  func recurrenceRule(for task: CheckvistTask) -> BarTaskerRecurrenceRule? {
    recurrence.recurrenceRule(for: task)
  }

  @MainActor func setRecurrenceRule(_ raw: String, for task: CheckvistTask) {
    if let error = recurrence.setRecurrenceRule(raw, for: task) {
      errorMessage = error
    }
  }

  @MainActor func clearRecurrenceRule(for task: CheckvistTask) {
    recurrence.clearRecurrenceRule(for: task)
  }

  // MARK: - Create next occurrence after marking done

  /// Call this after a recurring task is closed. Adds a sibling task with the next due date
  /// and transfers the recurrence rule to the new task.
  @MainActor func createNextOccurrence(for completedTask: CheckvistTask) async {
    guard let result = recurrence.computeNextOccurrence(
      for: completedTask,
      parseDueDateString: RecurrenceManager.parseDueDateString
    ) else {
      if recurrence.recurrenceRule(for: completedTask) != nil {
        errorMessage = "Could not calculate next occurrence for recurring task."
      }
      return
    }

    let completedTaskId = completedTask.id

    // Add the next sibling task with the same content.
    await addTask(
      content: completedTask.content,
      insertAfterTask: completedTask
    )

    // After addTask + fetchTopTask, find the newly created task (same content, next due).
    if let newTask = tasks.first(where: {
      $0.content == completedTask.content
        && $0.id != completedTaskId
        && recurrence.recurrenceRulesByTaskId[$0.id] == nil
    }) {
      // Set the due date on the new task.
      await updateTask(task: newTask, due: result.dueDateString)
      // Transfer the recurrence rule.
      recurrence.transferRule(from: completedTaskId, to: newTask.id, rule: result.savedRule)
    } else {
      // Clean up the recurrence rule for the now-closed task.
      recurrence.recurrenceRulesByTaskId.removeValue(forKey: completedTaskId)
    }
  }
}
