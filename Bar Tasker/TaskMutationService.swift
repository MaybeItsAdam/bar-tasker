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
/// Owns its raw task/auth state directly via a strong `TaskRepository`
/// reference (`listId`, `errorMessage`, `activeCredentials`, the active sync
/// plugin). Holds a `weak` reference to `AppCoordinator` for the cross-cutting
/// helpers that still live there (`fetchTopTask` indirection, `subtreeBlockRange`,
/// `isDescendant`, loading bracket, onboarding-dialog presentation,
/// pending-Obsidian reconciliation, navigation cursor).
@MainActor
final class TaskMutationService {
  private weak var coordinator: AppCoordinator?
  private let repository: TaskRepository

  init(coordinator: AppCoordinator, repository: TaskRepository) {
    self.coordinator = coordinator
    self.repository = repository
  }

  // MARK: - Failure Handling

  /// The single decision shared by every optimistic mutation when its server
  /// call throws: if the network is unreachable, keep the optimistic state and
  /// queue the work for replay (`whenOffline`); otherwise treat it as a genuine
  /// failure (`whenOnline`) — typically roll back the optimistic change and set
  /// an error message. Each caller supplies its own offline/online specifics;
  /// this only owns the reachability branch so it isn't re-derived per site.
  private func resolveMutationFailure(
    whenOffline: () -> Void,
    whenOnline: () -> Void
  ) {
    guard let coordinator else { return }
    if coordinator.repository.isNetworkReachable {
      whenOnline()
    } else {
      whenOffline()
    }
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
      (!isUndo && endpoint == "close") ? ancestorTaskIDs(for: task, in: coordinator.repository.tasks) : []

    let optimisticSnapshot: OptimisticCompletionSnapshot? =
      (!isUndo && (endpoint == "close" || endpoint == "invalidate"))
      ? applyOptimisticCompletion(for: task.id) : nil

    do {
      let success = try await coordinator.repository.activeSyncPlugin.performTaskAction(
        listId: repository.listId,
        taskId: task.id,
        action: action,
        credentials: repository.activeCredentials
      )
      if success {
        await reopenAncestorTasks(ancestorTaskIDsToKeepOpen)
        await coordinator.syncService.fetchTopTask()
      } else {
        if let optimisticSnapshot {
          restoreTasksSnapshot(optimisticSnapshot)
        }
        repository.errorMessage = "Failed to \(endpoint) task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.queueOfflineTaskAction(
            taskId: task.id, action: action, ancestorIds: ancestorTaskIDsToKeepOpen)
        },
        whenOnline: {
          if let optimisticSnapshot {
            self.restoreTasksSnapshot(optimisticSnapshot)
          }
          // The auth-unavailable case here rolls back silently (no message);
          // any other error surfaces a generic message.
          if case CheckvistSessionError.authenticationUnavailable = error {
            return
          }
          repository.errorMessage = "Error: \(error.localizedDescription)"
        }
      )
    }
  }

  /// Keep the optimistic close/reopen/invalidate in the UI and stash it for
  /// replay on reconnect. Ancestor reopens (used to defeat Checkvist's auto-
  /// complete-parent cascade) are queued too so the same reconciliation runs
  /// once we're back online.
  private func queueOfflineTaskAction(
    taskId: Int, action: CheckvistTaskAction, ancestorIds: [Int]
  ) {
    guard let coordinator else { return }
    coordinator.repository.enqueuePendingAction(
      PendingTaskAction(taskId: taskId, action: action))
    for ancestorId in ancestorIds {
      coordinator.repository.enqueuePendingAction(
        PendingTaskAction(taskId: ancestorId, action: .reopen))
    }
    repository.errorMessage = "Offline — will sync when connected."
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
    guard let index = coordinator.repository.tasks.firstIndex(where: { $0.id == task.id }) else {
      repository.errorMessage = "Task not found."
      return
    }
    let originalTask = coordinator.repository.tasks[index]
    coordinator.repository.tasks[index] = CheckvistTask(
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
        listId: repository.listId,
        taskId: task.id,
        content: content,
        due: due,
        credentials: repository.activeCredentials
      )
      if success {
        await coordinator.syncService.fetchTopTask()
      } else {
        coordinator.repository.tasks[index] = originalTask
        repository.errorMessage = "Failed to update task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          coordinator.repository.enqueuePendingMutation(
            taskId: task.id, content: content, due: due)
          repository.errorMessage = "Offline — will sync when connected."
        },
        whenOnline: {
          coordinator.repository.tasks[index] = originalTask
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error: \(error.localizedDescription)"
          }
        }
      )
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
      repository.errorMessage = "Task content cannot be empty."
      return
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }

    let optimisticTask = insertOptimisticSiblingTask(
      content: trimmedContent,
      afterTask: insertAfterTask,
      insertAtTopOfCurrentLevel: insertAtTopOfCurrentLevel
    )
    let optimisticTaskId = optimisticTask.id

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

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
          coordinator.repository.tasks.filter { ($0.parentId ?? 0) == coordinator.navigationState.currentParentId }
        if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
          apiPosition = idx + 2
        }
      }
    } else {
      apiPosition = 1
    }

    let parentIdForCreate = coordinator.navigationState.currentParentId == 0 ? nil : coordinator.navigationState.currentParentId
    let positionForCreate: Int? = apiPosition > 0 ? apiPosition : nil

    do {
      let newTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: trimmedContent,
        parentId: parentIdForCreate,
        position: positionForCreate,
        credentials: repository.activeCredentials
      )
      if let newTask {
        coordinator.undoService.lastAction = .add(taskId: newTask.id)
        await coordinator.syncService.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        repository.errorMessage = "Failed to add task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.queueOfflineCreate(
            tempId: optimisticTaskId,
            content: trimmedContent,
            parentId: parentIdForCreate,
            position: positionForCreate)
        },
        whenOnline: {
          self.removeOptimisticTask(id: optimisticTaskId)
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error adding task: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  /// Keeps the optimistic task in `tasks` and queues a create to fire on
  /// reconnect. Undo points at the temp id so a subsequent undo can either
  /// cancel the queued create or, after replay, delete the real task.
  private func queueOfflineCreate(
    tempId: Int, content: String, parentId: Int?, position: Int?
  ) {
    guard let coordinator else { return }
    coordinator.repository.enqueuePendingCreate(
      PendingTaskCreate(
        tempId: tempId, content: content, parentId: parentId, position: position))
    coordinator.undoService.lastAction = .add(taskId: tempId)
    repository.errorMessage = "Offline — will sync when connected."
  }

  func addTaskAsChild(content: String, parentId: Int) async {
    guard let coordinator else { return }

    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      repository.errorMessage = "Task content cannot be empty."
      return
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }
    let optimisticTask = insertOptimisticChildTask(content: trimmedContent, parentId: parentId)
    let optimisticTaskId = optimisticTask.id

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

    do {
      let newTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: trimmedContent,
        parentId: parentId,
        position: 1,
        credentials: repository.activeCredentials
      )
      if let newTask {
        coordinator.undoService.lastAction = .add(taskId: newTask.id)
        await coordinator.syncService.fetchTopTask()
      } else {
        removeOptimisticTask(id: optimisticTaskId)
        repository.errorMessage = "Failed to add task."
      }
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.queueOfflineCreate(
            tempId: optimisticTaskId, content: trimmedContent, parentId: parentId, position: 1)
        },
        whenOnline: {
          self.removeOptimisticTask(id: optimisticTaskId)
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Error: \(error.localizedDescription)"
          }
        }
      )
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

    // If the task is still a queued offline create, cancel that create
    // instead of round-tripping a create+delete through the server.
    if coordinator.repository.cancelPendingCreate(tempId: task.id) {
      _ = applyOptimisticCompletion(for: task.id)
      coordinator.reconcilePendingObsidianSyncQueueWithOpenTasks()
      return
    }

    guard let optimisticSnapshot = applyOptimisticCompletion(for: task.id) else {
      repository.errorMessage = "Task not found."
      return
    }
    coordinator.reconcilePendingObsidianSyncQueueWithOpenTasks()

    let listId = repository.listId
    let credentials = repository.activeCredentials
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
            coordinator?.repository.errorMessage = "Failed to delete task."
          }
        }
      } catch {
        await MainActor.run {
          guard let self, let coordinator else { return }
          self.resolveMutationFailure(
            whenOffline: {
              coordinator.repository.enqueuePendingDelete(taskId)
              self.repository.errorMessage = "Offline — will sync when connected."
            },
            whenOnline: {
              self.restoreTasksSnapshot(optimisticSnapshot)
              if case CheckvistSessionError.authenticationUnavailable = error {
                repository.setAuthenticationRequiredErrorIfNeeded()
              } else {
                self.repository.errorMessage = "Error: \(error.localizedDescription)"
              }
            }
          )
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
      repository.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
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
      repository.errorMessage = "No task selected."
      return
    }
    coordinator.preferences.quickAddSpecificParentTaskId = String(currentTask.id)
    coordinator.preferences.quickAddLocationMode = .specificParentTask
    repository.errorMessage = nil
  }

  func submitQuickAddTask(content: String, useSpecificLocation: Bool) async {
    guard let coordinator else { return }
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedContent.isEmpty else { return }

    let parentTaskId: Int?
    if useSpecificLocation {
      guard let specificTaskId = coordinator.quickAddSpecificParentTaskIdValue else {
        repository.errorMessage = "Set a valid Quick Add parent task ID in Preferences first."
        return
      }
      parentTaskId = specificTaskId
    } else {
      parentTaskId = nil
    }

    guard !repository.listId.isEmpty else {
      repository.errorMessage = "Choose a Checkvist list in Preferences to add tasks."
      coordinator.presentOnboardingDialogIfNeeded()
      return
    }

    repository.beginLoading()
    defer { repository.endLoading() }
    repository.errorMessage = nil

    do {
      let createdTask = try await coordinator.repository.activeSyncPlugin.createTask(
        listId: repository.listId,
        content: normalizedContent,
        parentId: parentTaskId,
        position: 1,
        credentials: repository.activeCredentials
      )
      guard let createdTask else {
        repository.errorMessage = "Quick add failed."
        return
      }
      coordinator.undoService.lastAction = .add(taskId: createdTask.id)
      await coordinator.syncService.fetchTopTask()
      coordinator.quickEntry.quickEntryMode = .search
      coordinator.quickEntry.quickEntryText = ""
      coordinator.quickEntry.isQuickEntryFocused = false
    } catch {
      resolveMutationFailure(
        whenOffline: {
          self.finishQuickAddOffline(content: normalizedContent, parentId: parentTaskId)
        },
        whenOnline: {
          if case CheckvistSessionError.authenticationUnavailable = error {
            repository.setAuthenticationRequiredErrorIfNeeded()
          } else {
            repository.errorMessage = "Quick add failed: \(error.localizedDescription)"
          }
        }
      )
    }
  }

  /// Quick add doesn't insert an optimistic task on the success path (it
  /// relies on the subsequent fetch to surface the new task). When offline
  /// there's no fetch to do, so insert one ourselves and queue the create.
  private func finishQuickAddOffline(content: String, parentId: Int?) {
    guard let coordinator else { return }
    let optimisticTask = CheckvistTask(
      id: nextOptimisticTaskId(),
      content: content,
      status: 0,
      due: nil,
      position: nil,
      parentId: parentId,
      level: nil
    )
    coordinator.repository.tasks.append(optimisticTask)
    queueOfflineCreate(
      tempId: optimisticTask.id, content: content, parentId: parentId, position: 1)
    coordinator.quickEntry.quickEntryMode = .search
    coordinator.quickEntry.quickEntryText = ""
    coordinator.quickEntry.isQuickEntryFocused = false
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
        repository.errorMessage = "Could not calculate next occurrence for recurring task."
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
    if let newTask = coordinator.repository.tasks.first(where: {
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
      parentId: coordinator.navigationState.currentParentId == 0 ? nil : coordinator.navigationState.currentParentId,
      level: nil
    )

    var insertIndex = coordinator.repository.tasks.endIndex
    if insertAtTopOfCurrentLevel {
      if coordinator.navigationState.currentParentId == 0 {
        insertIndex =
          coordinator.repository.tasks.firstIndex(where: { ($0.parentId ?? 0) == 0 })
          ?? coordinator.repository.tasks.endIndex
      } else if let parentRawIndex = coordinator.repository.tasks.firstIndex(where: {
        $0.id == coordinator.navigationState.currentParentId
      }) {
        insertIndex = parentRawIndex + 1
      }
    } else if let target = afterTask,
      let rawIndex = coordinator.repository.tasks.firstIndex(where: { $0.id == target.id })
    {
      var endIndex = rawIndex + 1
      while endIndex < coordinator.repository.tasks.count
        && coordinator.taskListViewModel.isDescendant(coordinator.repository.tasks[endIndex], of: target.id)
      {
        endIndex += 1
      }
      insertIndex = endIndex
    }

    if insertIndex <= coordinator.repository.tasks.endIndex {
      coordinator.repository.tasks.insert(optimisticTask, at: insertIndex)
    } else {
      coordinator.repository.tasks.append(optimisticTask)
    }

    if let insertedIndex = coordinator.currentLevelTasks.firstIndex(where: {
      $0.id == optimisticTask.id
    }) {
      coordinator.navigationState.currentSiblingIndex = insertedIndex
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
    if let parentRawIdx = coordinator.repository.tasks.firstIndex(where: { $0.id == parentId }) {
      coordinator.repository.tasks.insert(optimisticTask, at: parentRawIdx + 1)
    } else {
      coordinator.repository.tasks.append(optimisticTask)
    }
    return optimisticTask
  }

  private func removeOptimisticTask(id: Int) {
    guard let coordinator,
      let index = coordinator.repository.tasks.firstIndex(where: { $0.id == id })
    else { return }
    coordinator.repository.tasks.remove(at: index)
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
    guard let removingRange = coordinator.subtreeBlockRange(for: taskId, in: coordinator.repository.tasks)
    else { return nil }
    let removedTaskIds = Set(coordinator.repository.tasks[removingRange].map(\.id))
    let snapshot = OptimisticCompletionSnapshot(
      tasks: coordinator.repository.tasks,
      priorityTaskIdsByParentId: coordinator.repository.priorityTaskIdsByParentId,
      absolutePriorityTaskIds: coordinator.repository.absolutePriorityTaskIds,
      timerByTaskId: coordinator.timer.timerByTaskId,
      pendingObsidianSyncTaskIds: coordinator.integrations.pendingObsidianSyncTaskIds
    )
    coordinator.repository.tasks.removeSubrange(removingRange)
    repository.removeTasksFromPriorityQueue(removedTaskIds)
    coordinator.taskNavigationService.clampSelectionToVisibleRange()
    return snapshot
  }

  private func restoreTasksSnapshot(_ snapshot: OptimisticCompletionSnapshot) {
    guard let coordinator else { return }
    coordinator.repository.tasks = snapshot.tasks
    repository.savePriorityQueue(snapshot.priorityTaskIdsByParentId)
    coordinator.repository.saveAbsolutePriorityQueue(snapshot.absolutePriorityTaskIds)
    coordinator.timer.timerByTaskId = snapshot.timerByTaskId
    coordinator.integrations.savePendingObsidianSyncQueue(
      snapshot.pendingObsidianSyncTaskIds, listId: repository.listId)
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
          listId: repository.listId,
          taskId: ancestorID,
          action: .reopen,
          credentials: repository.activeCredentials
        )
      } catch CheckvistSessionError.authenticationUnavailable {
        repository.setAuthenticationRequiredErrorIfNeeded()
        return
      } catch {
        if repository.errorMessage == nil {
          repository.errorMessage = "Task completed, but a parent task could not be kept open."
        }
      }
    }
  }

  // MARK: - Priority mutations on the current task

  @MainActor func setPriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let coordinator, let task = coordinator.currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = repository.priorityTaskIdsByParentId
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    var scope = byParent[scopeId] ?? []
    let insertIndex = min(max(rank - 1, 0), scope.count)
    scope.insert(task.id, at: insertIndex)
    byParent[scopeId] = scope
    repository.savePriorityQueue(byParent)
    repository.errorMessage = nil

    if let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
      coordinator.navigationState.currentSiblingIndex = newIndex
    }
  }

  @MainActor func setAbsolutePriorityForCurrentTask(_ rank: Int) {
    guard rank >= 1, let coordinator, let task = coordinator.currentTask else { return }
    repository.setAbsolutePriority(taskId: task.id, rank: rank)
    repository.errorMessage = nil

    if let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
      coordinator.navigationState.currentSiblingIndex = newIndex
    }
  }

  @MainActor func sendCurrentTaskToPriorityBack() {
    guard let coordinator, let task = coordinator.currentTask else { return }

    let scopeId = task.parentId ?? 0
    var byParent = repository.priorityTaskIdsByParentId
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    var scope = byParent[scopeId] ?? []
    scope.append(task.id)
    byParent[scopeId] = scope
    repository.savePriorityQueue(byParent)
    repository.errorMessage = nil

    if let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
      coordinator.navigationState.currentSiblingIndex = newIndex
    }
  }

  @MainActor func clearPriorityForCurrentTask() {
    guard let coordinator, let task = coordinator.currentTask else { return }
    guard repository.prioritizedTaskIds.contains(task.id) else { return }
    var byParent = repository.priorityTaskIdsByParentId
    for (pid, ids) in byParent {
      let filtered = ids.filter { $0 != task.id }
      if filtered.count != ids.count {
        if filtered.isEmpty { byParent.removeValue(forKey: pid) }
        else { byParent[pid] = filtered }
      }
    }
    repository.savePriorityQueue(byParent)
    repository.errorMessage = nil

    if let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
      coordinator.navigationState.currentSiblingIndex = newIndex
    } else {
      coordinator.taskNavigationService.clampSelectionToVisibleRange()
    }
  }

  @MainActor func clearAbsolutePriorityForCurrentTask() {
    guard let coordinator, let task = coordinator.currentTask else { return }
    guard repository.absolutePrioritizedTaskIds.contains(task.id) else { return }
    repository.clearAbsolutePriority(taskId: task.id)
    repository.errorMessage = nil

    if let newIndex = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
      coordinator.navigationState.currentSiblingIndex = newIndex
    } else {
      coordinator.taskNavigationService.clampSelectionToVisibleRange()
    }
  }
}
