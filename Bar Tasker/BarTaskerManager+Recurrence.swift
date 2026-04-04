import Foundation

extension BarTaskerManager {

  // MARK: - Recurrence rule storage

  /// Returns the recurrence rule for a task, or nil if none is set.
  func recurrenceRule(for task: CheckvistTask) -> BarTaskerRecurrenceRule? {
    guard let raw = recurrenceRulesByTaskId[task.id], !raw.isEmpty else { return nil }
    return BarTaskerRecurrenceRule(raw: raw)
  }

  /// Sets the recurrence rule for a task from a raw string.
  @MainActor func setRecurrenceRule(_ raw: String, for task: CheckvistTask) {
    guard let rule = BarTaskerRecurrenceRule.from(raw) else {
      errorMessage = "Unrecognised repeat rule: \"\(raw)\". Try: daily, weekdays, weekly, every 3 days, every monday."
      return
    }
    recurrenceRulesByTaskId[task.id] = rule.raw
    persistRecurrenceRules()
  }

  /// Removes the recurrence rule for a task.
  @MainActor func clearRecurrenceRule(for task: CheckvistTask) {
    recurrenceRulesByTaskId.removeValue(forKey: task.id)
    persistRecurrenceRules()
  }

  // MARK: - Create next occurrence after marking done

  /// Call this after a recurring task is closed. Adds a sibling task with the next due date
  /// and transfers the recurrence rule to the new task.
  @MainActor func createNextOccurrence(for completedTask: CheckvistTask) async {
    guard let rule = recurrenceRule(for: completedTask) else { return }

    // Determine the base date for calculating next due:
    // prefer the task's current due date so "every monday" stays on track.
    let baseDate: Date
    if let dueString = completedTask.due, !dueString.isEmpty,
       let parsedDue = parseDueDateString(dueString) {
      baseDate = parsedDue
    } else {
      baseDate = Date()
    }

    guard let nextDate = rule.nextDueDate(from: baseDate) else {
      errorMessage = "Could not calculate next occurrence for rule: \(rule.raw)"
      return
    }

    let dueDateString = dueDateFormatter.string(from: nextDate)

    // Save the rule for the completed task's ID so we can transfer it after creation.
    let savedRule = rule.raw
    let completedTaskId = completedTask.id

    // Add the next sibling task with the same content.
    await addTask(
      content: completedTask.content,
      insertAfterTask: completedTask
    )

    // After addTask + fetchTopTask, find the newly created task (same content, next due).
    // The new task will have been inserted right after the completed task's position
    // and will be present in the refreshed tasks list.
    // We identify it by content match and absence of a recurrence rule.
    if let newTask = tasks.first(where: {
      $0.content == completedTask.content
        && $0.id != completedTaskId
        && recurrenceRulesByTaskId[$0.id] == nil
    }) {
      // Set the due date on the new task.
      await updateTask(task: newTask, due: dueDateString)
      // Transfer the recurrence rule.
      recurrenceRulesByTaskId[newTask.id] = savedRule
      persistRecurrenceRules()
    }

    // Clean up the recurrence rule for the now-closed task.
    recurrenceRulesByTaskId.removeValue(forKey: completedTaskId)
    persistRecurrenceRules()
  }

  // MARK: - Persistence

  func persistRecurrenceRules() {
    let stringKeyed = Dictionary(
      uniqueKeysWithValues: recurrenceRulesByTaskId.map { ("\($0.key)", $0.value) }
    )
    preferencesStore.set(stringKeyed, for: .recurrenceRulesByTaskId)
  }

  // MARK: - Private helpers

  private func parseDueDateString(_ raw: String) -> Date? {
    let formatters: [DateFormatter] = [
      makeDueFormatter("yyyy-MM-dd HH:mm:ss Z"),
      makeDueFormatter("yyyy-MM-dd HH:mm:ss"),
      makeDueFormatter("yyyy-MM-dd"),
    ]
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
    for f in formatters {
      if let d = f.date(from: trimmed) { return d }
    }
    return nil
  }

  private func makeDueFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
  }

  private var dueDateFormatter: DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }
}
