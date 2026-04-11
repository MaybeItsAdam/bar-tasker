import AppKit
import OSLog
import SwiftUI

extension AppCoordinator {
  // MARK: - Mark Done / Reopen / Invalidate

  @MainActor func markCurrentTaskDone() async {
    guard let task = currentTask else { return }
    // Multi-step haptic pattern for stronger tactile feedback.
    // Each sleep must propagate CancellationError so that navigating away
    // or switching tasks stops the sequence before taskAction fires.
    do {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      try await Task.sleep(nanoseconds: 60_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      // Spring the checkmark in.
      withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
        quickEntry.completingTaskId = task.id
      }
      // Confirmation tap.
      try await Task.sleep(nanoseconds: 120_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // Hold so strikethrough and pulse are visible.
      try await Task.sleep(nanoseconds: 360_000_000)
    } catch {
      // Cancelled — clean up animation state and bail out without completing.
      withAnimation { quickEntry.completingTaskId = nil }
      return
    }
    withAnimation { quickEntry.completingTaskId = nil }
    await taskAction(task, endpoint: "close")
    await createNextOccurrence(for: task)
  }

  @MainActor func reopenCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "reopen")
  }

  @MainActor func invalidateCurrentTask() async {
    guard let task = currentTask else { return }
    await taskAction(task, endpoint: "invalidate")
  }

  /// POST to a Checkvist task action endpoint (close, reopen, invalidate)
  @MainActor func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false)
    async
  {

    if !isUndo {
      if endpoint == "close" {
        lastUndo = .markDone(taskId: task.id)
      } else if endpoint == "invalidate" {
        lastUndo = .invalidate(taskId: task.id)
      }
    }

    guard let action = CheckvistTaskAction(rawValue: endpoint) else { return }
    let ancestorTaskIDsToKeepOpen =
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await repository.activeSyncPlugin.performTaskAction(
        listId: listId,
        taskId: task.id,
        action: action,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
        if !ancestorTaskIDsToKeepOpen.isEmpty {
          let reopenedAny = await reopenMissingAncestorTasksIfNeeded(ancestorTaskIDsToKeepOpen)
          if reopenedAny {
            await fetchTopTask()
          }
        }
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        errorMessage = "Failed to \(endpoint) task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
    } catch {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Update

  @MainActor func updateTask(
    task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false
  ) async {

    if !isUndo {
      lastUndo = .update(taskId: task.id, oldContent: task.content, oldDue: task.due)
    }

    // Optimistic local update so UI reflects the change immediately.
    guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
      errorMessage = "Task not found."
      return
    }
    let originalTask = tasks[index]
    tasks[index] = CheckvistTask(
      id: originalTask.id,
      content: content ?? originalTask.content,
      status: originalTask.status,
      due: due ?? originalTask.due,
      position: originalTask.position,
      parentId: originalTask.parentId,
      level: originalTask.level,
      notes: originalTask.notes,
      updatedAt: originalTask.updatedAt
    )

    do {
      let success = try await repository.activeSyncPlugin.updateTask(
        listId: listId,
        taskId: task.id,
        content: content,
        due: due,
        credentials: activeCredentials
      )
      if success {
        await fetchTopTask()
      } else {
        tasks[index] = originalTask
        errorMessage = "Failed to update task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if !repository.isNetworkReachable {
        repository.pendingTaskMutations[task.id] = (content: content, due: due)
        errorMessage = "Offline — will sync when connected."
      } else {
        tasks[index] = originalTask
        setAuthenticationRequiredErrorIfNeeded()
      }
    } catch {
      if !repository.isNetworkReachable {
        repository.pendingTaskMutations[task.id] = (content: content, due: due)
        errorMessage = "Offline — will sync when connected."
      } else {
        tasks[index] = originalTask
        errorMessage = "Error: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Add

  @MainActor
  func addTask(
    content: String,
    insertAfterTask: CheckvistTask? = nil,
    insertAtTopOfCurrentLevel: Bool = false
  ) async {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      errorMessage = "Task content cannot be empty."
      return
    }

    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }

    let optimisticTask = insertOptimisticSiblingTask(
      content: trimmedContent,
      afterTask: insertAfterTask,
      insertAtTopOfCurrentLevel: insertAtTopOfCurrentLevel
    )
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    // Find current position to insert right below
    var apiPosition = 0
    let target = insertAfterTask ?? currentTask
    if insertAtTopOfCurrentLevel {
      apiPosition = 1
    } else if let current = target {
      if let targetPos = current.position {
        apiPosition = targetPos + 1
      } else {
        let siblings = tasks.filter { ($0.parentId ?? 0) == currentParentId }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 2
        }
      }
    } else {
      apiPosition = 1
    }

    let parentIdForCreate = currentParentId == 0 ? nil : currentParentId
    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await repository.activeSyncPlugin.createTask(
        listId: listId,
        content: trimmedContent,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error adding task: \(error.localizedDescription)"
    }
  }

  @MainActor func addTaskAsChild(content: String, parentId: Int) async {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      errorMessage = "Task content cannot be empty."
      return
    }

    guard !listId.isEmpty else {
      errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      presentOnboardingDialogIfNeeded()
      return
    }
    let optimisticTask = insertOptimisticChildTask(content: trimmedContent, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    beginLoading()
    defer { endLoading() }
    errorMessage = nil

    do {
      let newTask = try await repository.activeSyncPlugin.createTask(
        listId: listId,
        content: trimmedContent,
        parentId: parentId,
        position: 1,
        credentials: activeCredentials
      )
      if let newTask {
        lastUndo = .add(taskId: newTask.id)
        await fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Delete

  @MainActor func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {

    if !isUndo {
      lastUndo = nil  // Clear undo history since we don't support recovering hard-deleted tasks yet
    }

    beginLoading()
    defer { endLoading() }

    await runBooleanMutation(
      failureMessage: "Failed to delete task.",
      action: {
        try await self.repository.activeSyncPlugin.deleteTask(
          listId: self.listId,
          taskId: task.id,
          credentials: self.activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }

  // MARK: - Optimistic Updates

  @MainActor
  private func insertOptimisticSiblingTask(
    content: String,
    afterTask: CheckvistTask?,
    insertAtTopOfCurrentLevel: Bool = false
  )
    -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: currentParentId == 0 ? nil : currentParentId,
      level: nil
    )

    var insertIndex = tasks.endIndex
    if insertAtTopOfCurrentLevel {
      if currentParentId == 0 {
        insertIndex =
          tasks.firstIndex(where: { ($0.parentId ?? 0) == 0 }) ?? tasks.endIndex
      } else if let parentRawIndex = tasks.firstIndex(where: { $0.id == currentParentId }) {
        insertIndex = parentRawIndex + 1
      }
    } else if let target = afterTask, let rawIndex = tasks.firstIndex(where: { $0.id == target.id })
    {
      var endIndex = rawIndex + 1
      while endIndex < tasks.count && isDescendant(tasks[endIndex], of: target.id) {
        endIndex += 1
      }
      insertIndex = endIndex
    }

    if insertIndex <= tasks.endIndex {
      tasks.insert(optimisticTask, at: insertIndex)
    } else {
      tasks.append(optimisticTask)
    }

    if let insertedIndex = currentLevelTasks.firstIndex(where: { $0.id == optimisticTask.id }) {
      currentSiblingIndex = insertedIndex
    }
    return optimisticTask
  }

  @MainActor private func insertOptimisticChildTask(content: String, parentId: Int) -> CheckvistTask
  {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )

    if let parentRawIdx = tasks.firstIndex(where: { $0.id == parentId }) {
      tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      tasks.append(optimisticTask)
    }
    return optimisticTask
  }

  @MainActor private func removeOptimisticTask(id: Int) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks.remove(at: index)
    clampSelectionToVisibleRange()
  }

  private struct OptimisticCompletionSnapshot {
    let tasks: [CheckvistTask]
    let priorityTaskIds: [Int]
    let timerByTaskId: [Int: TimeInterval]
    let pendingObsidianSyncTaskIds: [Int]
  }

  @MainActor private func applyOptimisticCompletion(for taskId: Int)
    -> OptimisticCompletionSnapshot?
  {
    guard let removingRange = subtreeBlockRange(for: taskId, in: tasks) else { return nil }
    let removedTaskIds = Set(tasks[removingRange].map(\.id))
    let snapshot = OptimisticCompletionSnapshot(
      tasks: tasks,
      priorityTaskIds: repository.priorityTaskIds,
      timerByTaskId: timer.timerByTaskId,
      pendingObsidianSyncTaskIds: integrations.pendingObsidianSyncTaskIds
    )
    tasks.removeSubrange(removingRange)
    removeTasksFromPriorityQueue(removedTaskIds)
    clampSelectionToVisibleRange()
    return snapshot
  }

  @MainActor private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    tasks = snapshot.tasks
    savePriorityQueue(snapshot.priorityTaskIds)
    timer.timerByTaskId = snapshot.timerByTaskId
    integrations.savePendingObsidianSyncQueue(snapshot.pendingObsidianSyncTaskIds, listId: listId)
    clampSelectionToVisibleRange()
  }

  private func nextOptimisticTaskId() -> Int {
    -Int.random(in: 1...1_000_000)
  }


  // MARK: - Ancestor Helpers

  private func ancestorTaskIDs(for task: CheckvistTask, in taskList: [CheckvistTask]) -> [Int] {
    var taskByID: [Int: CheckvistTask] = [:]
    for listedTask in taskList {
      taskByID[listedTask.id] = listedTask
    }

    var ancestorIDs: [Int] = []
    var nextParentID = task.parentId ?? 0
    while nextParentID != 0 {
      ancestorIDs.append(nextParentID)
      guard let parent = taskByID[nextParentID] else { break }
      nextParentID = parent.parentId ?? 0
    }

    return ancestorIDs
  }

  @MainActor private func reopenMissingAncestorTasksIfNeeded(_ ancestorTaskIDs: [Int]) async -> Bool
  {
    let openTaskIDs = Set(tasks.map(\.id))
    let missingAncestorIDs = ancestorTaskIDs.filter { !openTaskIDs.contains($0) }
    guard !missingAncestorIDs.isEmpty else { return false }

    var reopenedAny = false
    for ancestorID in missingAncestorIDs {
      do {
        let success = try await repository.activeSyncPlugin.performTaskAction(
          listId: listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: activeCredentials
        )
        if success {
          reopenedAny = true
        }
      } catch CheckvistSessionError.authenticationUnavailable {
        setAuthenticationRequiredErrorIfNeeded()
        break
      } catch {
        if errorMessage == nil {
          errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }

    return reopenedAny
  }

  // MARK: - Recurrence (cross-cutting: recurrence + task CRUD)

  /// Call this after a recurring task is closed. Adds a sibling task with the next due date
  /// and transfers the recurrence rule to the new task.
  @MainActor func createNextOccurrence(for completedTask: CheckvistTask) async {
    guard
      let result = recurrence.computeNextOccurrence(
        for: completedTask,
        parseDueDateString: RecurrenceManager.parseDueDateString
      )
    else {
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

  // MARK: - Recurrence Convenience Accessors

  func recurrenceRule(for task: CheckvistTask) -> RecurrenceRule? {
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
}
