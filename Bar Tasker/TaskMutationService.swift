import AppKit
import Foundation
import OSLog
import SwiftUI

/// Owns task mutations: mark-done / reopen / invalidate, edit, add (sibling
/// or child), delete, the QuickAdd flow, and the recurrence cross-cutting that
/// fires the next occurrence after a recurring task is closed.
///
/// Currently app-only because `markCurrentTaskDone` drives haptics
/// (`NSHapticFeedbackManager`) and the completion-checkmark animation
/// (`withAnimation`). Promoting this into `BarTaskerAppLogic` so coordinator-
/// level mutation paths can be unit-tested would mean abstracting both behind
/// protocols (a `HapticFeedback` and a SwiftUI-free animation hook) plus
/// breaking the coordinator dependency surface listed below; that is a
/// separate piece of work and is called out in the architecture plan.
///
/// Like the other Phase-3 services, this holds a `weak` reference to
/// `AppCoordinator` for the cross-cutting state it has to read/write
/// (`tasks`, `errorMessage`, navigation cursor) and for helpers
/// that still live on the coordinator (`fetchTopTask`, `subtreeBlockRange`,
/// `isDescendant`, loading bracket, onboarding-dialog presentation,
/// pending-Obsidian reconciliation).
@MainActor
final class TaskMutationService {
  private weak var coordinator: AppCoordinator?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Mark Done / Reopen / Invalidate

  func markCurrentTaskDone() async {
    guard let coordinator, let task = coordinator.currentTask else { return }

    // Multi-step haptic pattern for stronger tactile feedback. Each sleep
    // must propagate CancellationError so navigating away or switching tasks
    // stops the sequence before taskAction fires.
    do {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      try await Task.sleep(nanoseconds: 30_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
      withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
        coordinator.quickEntry.completingTaskId = task.id
      }
      // Confirmation tap, around when the strikethrough finishes drawing.
      try await Task.sleep(nanoseconds: 100_000_000)
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // Brief hold so the strikethrough is perceptible without dragging out
      // removal.
      try await Task.sleep(nanoseconds: 80_000_000)
    } catch {
      withAnimation { coordinator.quickEntry.completingTaskId = nil }
      return
    }
    withAnimation { coordinator.quickEntry.completingTaskId = nil }
    await taskAction(task, endpoint: "close")
    await createNextOccurrence(for: task)
  }

  func reopenCurrentTask() async {
    guard let coordinator, let task = coordinator.currentTask else { return }
    await taskAction(task, endpoint: "reopen")
  }

  func invalidateCurrentTask() async {
    guard let coordinator, let task = coordinator.currentTask else { return }
    await taskAction(task, endpoint: "invalidate")
  }

  /// POST to a Checkvist task action endpoint (close, reopen, invalidate).
  func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false) async {
    guard let coordinator else { return }

    if !isUndo {
      if endpoint == "close" {
        coordinator.undoService.lastAction = .markDone(taskId: task.id)
      } else if endpoint == "invalidate" {
        coordinator.undoService.lastAction = .invalidate(taskId: task.id)
      }
    }

    guard let action = CheckvistTaskAction(rawValue: endpoint) else { return }
    let ancestorTaskIDsToKeepOpen =
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: coordinator.tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await coordinator.repository.activeSyncPlugin.performTaskAction(
        listId: coordinator.listId,
        taskId: task.id,
        action: action,
        credentials: coordinator.activeCredentials
      )
      if success {
        await reopenAncestorTasks(ancestorTaskIDsToKeepOpen)
        await coordinator.syncService.fetchTopTask()
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        coordinator.errorMessage = "Failed to \(endpoint) task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
    } catch {
      if let optimisticSnapshot {
        restoreTasksSnapshot(optimisticSnapshot)
      }
      coordinator.errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Update

  func updateTask(
    task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false
  ) async {
    guard let coordinator else { return }

    if !isUndo {
      coordinator.undoService.lastAction = .update(
        taskId: task.id, oldContent: task.content, oldDue: task.due)
    }

    // Optimistic local update so UI reflects the change immediately.
    guard let index = coordinator.tasks.firstIndex(where: { $0.id == task.id }) else {
      coordinator.errorMessage = "Task not found."
      return
    }
    let originalTask = coordinator.tasks[index]
    coordinator.tasks[index] = CheckvistTask(
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
      let success = try await coordinator.repository.activeSyncPlugin.updateTask(
        listId: coordinator.listId,
        taskId: task.id,
        content: content,
        due: due,
        credentials: coordinator.activeCredentials
      )
      if success {
        await coordinator.syncService.fetchTopTask()
      } else {
        coordinator.tasks[index] = originalTask
        coordinator.errorMessage = "Failed to update task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      if !coordinator.repository.isNetworkReachable {
        coordinator.repository.pendingTaskMutations[task.id] = (content: content, due: due)
        coordinator.errorMessage = "Offline — will sync when connected."
      } else {
        coordinator.tasks[index] = originalTask
        coordinator.setAuthenticationRequiredErrorIfNeeded()
      }
    } catch {
      if !coordinator.repository.isNetworkReachable {
        coordinator.repository.pendingTaskMutations[task.id] = (content: content, due: due)
        coordinator.errorMessage = "Offline — will sync when connected."
      } else {
        coordinator.tasks[index] = originalTask
        coordinator.errorMessage = "Error: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Add

  func addTask(
    content: String,
    insertAfterTask: CheckvistTask? = nil,
    insertAtTopOfCurrentLevel: Bool = false
  ) async {
    guard let coordinator else { return }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      coordinator.errorMessage = "Task content cannot be empty."
      return
    }

    guard !coordinator.listId.isEmpty else {
      coordinator.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }

    let optimisticTask = insertOptimisticSiblingTask(
      content: trimmedContent,
      afterTask: insertAfterTask,
      insertAtTopOfCurrentLevel: insertAtTopOfCurrentLevel
    )
    let optimisticTaskId = optimisticTask.id

    coordinator.beginLoading()
    defer { coordinator.endLoading() }
    coordinator.errorMessage = nil

    // Find current position to insert right below.
    var apiPosition = 0
    let target = insertAfterTask ?? coordinator.currentTask
    if insertAtTopOfCurrentLevel {
      apiPosition = 1
    } else if let current = target {
      if let targetPos = current.position {
        apiPosition = targetPos + 1
      } else {
        let siblings =
          coordinator.tasks.filter { ($0.parentId ?? 0) == coordinator.currentParentId }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 2
        }
      }
    } else {
      apiPosition = 1
    }

    let parentIdForCreate = coordinator.currentParentId == 0 ? nil : coordinator.currentParentId
    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: coordinator.listId,
        content: trimmedContent,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: coordinator.activeCredentials
      )
      if let newTask {
        coordinator.undoService.lastAction = .add(taskId: newTask.id)
        await coordinator.syncService.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        coordinator.errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      coordinator.setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      coordinator.errorMessage = "Error adding task: \(error.localizedDescription)"
    }
  }

  func addTaskAsChild(content: String, parentId: Int) async {
    guard let coordinator else { return }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      coordinator.errorMessage = "Task content cannot be empty."
      return
    }

    guard !coordinator.listId.isEmpty else {
      coordinator.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }
    let optimisticTask = insertOptimisticChildTask(content: trimmedContent, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    coordinator.beginLoading()
    defer { coordinator.endLoading() }
    coordinator.errorMessage = nil

    do {
      let newTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: coordinator.listId,
        content: trimmedContent,
        parentId: parentId,
        position: 1,
        credentials: coordinator.activeCredentials
      )
      if let newTask {
        coordinator.undoService.lastAction = .add(taskId: newTask.id)
        await coordinator.syncService.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        coordinator.errorMessage = "Failed to add task."
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      removeOptimisticTask(id: optimisticTaskId)
      coordinator.setAuthenticationRequiredErrorIfNeeded()
    } catch {
      removeOptimisticTask(id: optimisticTaskId)
      coordinator.errorMessage = "Error: \(error.localizedDescription)"
    }
  }

  // MARK: - Delete

  func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {
    guard let coordinator else { return }

    if !isUndo {
      // Clear undo history since we don't support recovering hard-deleted
      // tasks yet.
      coordinator.undoService.lastAction = nil
    }
    guard let optimisticSnapshot = applyOptimisticCompletion(for: task.id) else {
      coordinator.errorMessage = "Task not found."
      return
    }
    coordinator.reconcilePendingObsidianSyncQueueWithOpenTasks()

    let listId = coordinator.listId
    let credentials = coordinator.activeCredentials
    let plugin = coordinator.repository.activeSyncPlugin
    let taskId = task.id

    Task { [weak self, weak coordinator] in
      do {
        let success = try await plugin.deleteTask(
          listId: listId,
          taskId: taskId,
          credentials: credentials
        )
        if !success {
          await MainActor.run {
            guard let self else { return }
            self.restoreTasksSnapshot(optimisticSnapshot)
            coordinator?.errorMessage = "Failed to delete task."
          }
        }
      } catch CheckvistSessionError.authenticationUnavailable {
        await MainActor.run {
          guard let self else { return }
          self.restoreTasksSnapshot(optimisticSnapshot)
          coordinator?.setAuthenticationRequiredErrorIfNeeded()
        }
      } catch {
        await MainActor.run {
          guard let self else { return }
          self.restoreTasksSnapshot(optimisticSnapshot)
          coordinator?.errorMessage = "Error: \(error.localizedDescription)"
        }
      }
    }
  }

  // MARK: - Quick Add

  /// Returns true when QuickAdd was successfully primed (focus moved to the
  /// entry field). Returns false when the user has chosen specific-parent
  /// mode but hasn't configured a parent task ID yet — caller leaves focus
  /// alone in that case.
  func beginQuickAddEntry(preferSpecificLocation: Bool? = nil) -> Bool {
    guard let coordinator else { return false }
    let useSpecificLocation =
      preferSpecificLocation ?? (coordinator.preferences.quickAddLocationMode == .specificParentTask)
    if useSpecificLocation && coordinator.quickAddSpecificParentTaskIdValue == nil {
      coordinator.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
      return false
    }

    coordinator.quickEntry.pendingDeleteConfirmation = false
    coordinator.quickEntry.commandSuggestionIndex = 0
    coordinator.quickEntry.quickEntryMode =
      useSpecificLocation ? .quickAddSpecific : .quickAddDefault
    coordinator.quickEntry.quickEntryText = ""
    coordinator.quickEntry.isQuickEntryFocused = true
    return true
  }

  func setQuickAddSpecificLocationToCurrentTask() {
    guard let coordinator else { return }
    guard let currentTask = coordinator.currentTask else {
      coordinator.errorMessage = "No task selected."
      return
    }
    coordinator.preferences.quickAddSpecificParentTaskId = String(currentTask.id)
    coordinator.preferences.quickAddLocationMode = .specificParentTask
    coordinator.errorMessage = nil
  }

  func submitQuickAddTask(content: String, useSpecificLocation: Bool) async {
    guard let coordinator else { return }
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContent.isEmpty else { return }

    let parentTaskId: Int?
    if useSpecificLocation {
      guard let specificTaskId = coordinator.quickAddSpecificParentTaskIdValue else {
        coordinator.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
        return
      }
      parentTaskId = specificTaskId
    } else {
      parentTaskId = nil
    }

    guard !coordinator.listId.isEmpty else {
      coordinator.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }

    coordinator.beginLoading()
    defer { coordinator.endLoading() }
    coordinator.errorMessage = nil

    do {
      let createdTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: coordinator.listId,
        content: normalizedContent,
        parentId: parentTaskId,
        position: 1,
        credentials: coordinator.activeCredentials
      )
      guard let createdTask else {
        coordinator.errorMessage = "Quick add failed."
        return
      }
      coordinator.undoService.lastAction = .add(taskId: createdTask.id)
      await coordinator.syncService.fetchTopTask()
      coordinator.quickEntry.quickEntryMode = .search
      coordinator.quickEntry.quickEntryText = ""
      coordinator.quickEntry.isQuickEntryFocused = false
    } catch CheckvistSessionError.authenticationUnavailable {
      coordinator.setAuthenticationRequiredErrorIfNeeded()
    } catch {
      coordinator.errorMessage = "Quick add failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Recurrence (cross-cutting: recurrence + task CRUD)

  /// Call after a recurring task is closed. Adds a sibling task with the next
  /// due date and transfers the recurrence rule to the new task.
  func createNextOccurrence(for completedTask: CheckvistTask) async {
    guard let coordinator else { return }
    guard
      let result = coordinator.recurrence.computeNextOccurrence(
        for: completedTask,
        parseDueDateString: RecurrenceManager.parseDueDateString
      )
    else {
      if coordinator.recurrence.recurrenceRule(for: completedTask) != nil {
        coordinator.errorMessage = "Could not calculate next occurrence for recurring task."
      }
      return
    }

    let completedTaskId = completedTask.id

    // Add the next sibling task with the same content.
    await addTask(
      content: completedTask.content,
      insertAfterTask: completedTask
    )

    // After addTask + fetchTopTask, find the newly created task (same content,
    // next due).
    if let newTask = coordinator.tasks.first(where: {
      $0.content == completedTask.content
        && $0.id != completedTaskId
        && coordinator.recurrence.recurrenceRulesByTaskId[$0.id] == nil
    }) {
      await updateTask(task: newTask, due: result.dueDateString)
      coordinator.recurrence.transferRule(
        from: completedTaskId, to: newTask.id, rule: result.savedRule)
    } else {
      coordinator.recurrence.recurrenceRulesByTaskId.removeValue(forKey: completedTaskId)
    }
  }

  // MARK: - Optimistic Updates

  private func insertOptimisticSiblingTask(
    content: String,
    afterTask: CheckvistTask?,
    insertAtTopOfCurrentLevel: Bool = false
  ) -> CheckvistTask {
    guard let coordinator else {
      return CheckvistTask(
        id: nextOptimisticTaskId(), content: content, status: 0, due: nil,
        position: nil, parentId: nil, level: nil)
    }

    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: coordinator.currentParentId == 0 ? nil : coordinator.currentParentId,
      level: nil
    )

    var insertIndex = coordinator.tasks.endIndex
    if insertAtTopOfCurrentLevel {
      if coordinator.currentParentId == 0 {
        insertIndex =
          coordinator.tasks.firstIndex(where: { ($0.parentId ?? 0) == 0 })
          ?? coordinator.tasks.endIndex
      } else if let parentRawIndex = coordinator.tasks.firstIndex(where: {
        $0.id == coordinator.currentParentId
      }) {
        insertIndex = parentRawIndex + 1
      }
    } else if let target = afterTask,
      let rawIndex = coordinator.tasks.firstIndex(where: { $0.id == target.id })
    {
      var endIndex = rawIndex + 1
      while endIndex < coordinator.tasks.count
        && coordinator.isDescendant(coordinator.tasks[endIndex], of: target.id)
      {
        endIndex += 1
      }
      insertIndex = endIndex
    }

    if insertIndex <= coordinator.tasks.endIndex {
      coordinator.tasks.insert(optimisticTask, at: insertIndex)
    } else {
      coordinator.tasks.append(optimisticTask)
    }

    if let insertedIndex = coordinator.currentLevelTasks.firstIndex(where: {
      $0.id == optimisticTask.id
    }) {
      coordinator.currentSiblingIndex = insertedIndex
    }
    return optimisticTask
  }

  private func insertOptimisticChildTask(content: String, parentId: Int) -> CheckvistTask {
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )

    guard let coordinator else { return optimisticTask }
    if let parentRawIdx = coordinator.tasks.firstIndex(where: { $0.id == parentId }) {
      coordinator.tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      coordinator.tasks.append(optimisticTask)
    }
    return optimisticTask
  }

  private func removeOptimisticTask(id: Int) {
    guard let coordinator,
      let index = coordinator.tasks.firstIndex(where: { $0.id == id })
    else { return }
    coordinator.tasks.remove(at: index)
    coordinator.taskNavigationService.clampSelectionToVisibleRange()
  }

  fileprivate struct OptimisticCompletionSnapshot {
    let tasks: [CheckvistTask]
    let priorityTaskIdsByParentId: [Int: [Int]]
    let absolutePriorityTaskIds: [Int]
    let timerByTaskId: [Int: TimeInterval]
    let pendingObsidianSyncTaskIds: [Int]
  }

  private func applyOptimisticCompletion(for taskId: Int) -> OptimisticCompletionSnapshot? {
    guard let coordinator else { return nil }
    guard let removingRange = coordinator.subtreeBlockRange(for: taskId, in: coordinator.tasks)
    else { return nil }
    let removedTaskIds = Set(coordinator.tasks[removingRange].map(\.id))
    let snapshot = OptimisticCompletionSnapshot(
      tasks: coordinator.tasks,
      priorityTaskIdsByParentId: coordinator.repository.priorityTaskIdsByParentId,
      absolutePriorityTaskIds: coordinator.repository.absolutePriorityTaskIds,
      timerByTaskId: coordinator.timer.timerByTaskId,
      pendingObsidianSyncTaskIds: coordinator.integrations.pendingObsidianSyncTaskIds
    )
    coordinator.tasks.removeSubrange(removingRange)
    coordinator.removeTasksFromPriorityQueue(removedTaskIds)
    coordinator.taskNavigationService.clampSelectionToVisibleRange()
    return snapshot
  }

  private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    guard let coordinator else { return }
    coordinator.tasks = snapshot.tasks
    coordinator.savePriorityQueue(snapshot.priorityTaskIdsByParentId)
    coordinator.repository.saveAbsolutePriorityQueue(snapshot.absolutePriorityTaskIds)
    coordinator.timer.timerByTaskId = snapshot.timerByTaskId
    coordinator.integrations.savePendingObsidianSyncQueue(
      snapshot.pendingObsidianSyncTaskIds, listId: coordinator.listId)
    coordinator.taskNavigationService.clampSelectionToVisibleRange()
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

  /// Sends `.reopen` for each ancestor unconditionally to defeat Checkvist's
  /// auto-complete-parent cascade. Reopen is idempotent on already-open tasks,
  /// and sending it before the next fetch eliminates the race where a still-
  /// pending cascade closes an ancestor between fetches.
  private func reopenAncestorTasks(_ ancestorTaskIDs: [Int]) async {
    guard let coordinator, !ancestorTaskIDs.isEmpty else { return }
    for ancestorID in ancestorTaskIDs {
      do {
        _ = try await coordinator.repository.activeSyncPlugin.performTaskAction(
          listId: coordinator.listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: coordinator.activeCredentials
        )
      } catch CheckvistSessionError.authenticationUnavailable {
        coordinator.setAuthenticationRequiredErrorIfNeeded()
        return
      } catch {
        if coordinator.errorMessage == nil {
          coordinator.errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }
  }
}
