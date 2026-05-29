import Foundation
import OSLog

/// Owns the network-facing surface of the coordinator: authentication, list
/// management, fetching tasks, the offline-mutation flush, and the
/// position/parent edits (move, indent, unindent) that need a serialised
/// reorder queue talking to the active sync plugin.
///
/// Like the other Phase-3 services, it keeps a `weak` reference to
/// `AppCoordinator` for state it doesn't yet own (`tasks`, `errorMessage`,
/// the navigation cursor, sibling managers like `kanban`, `timer`,
/// `focusSessionManager`, `integrations`) and for forwarding helpers that
/// still live on the coordinator (`updateTask`, `applyOptimisticMoveAndSync`,
/// `subtreeBlockRange`, `runBooleanMutation`, `withLoadingState`,
/// `beginLoading` / `endLoading`, `savePriorityQueue`,
/// `reconcilePriorityQueueWithOpenTasks`,
/// `reconcilePendingObsidianSyncQueueWithOpenTasks`,
/// `setAuthenticationRequiredErrorIfNeeded`).
@MainActor
final class SyncService {
  private weak var coordinator: AppCoordinator?
  private let logger = Logger(
    subsystem: "uk.co.maybeitsadam.bar-tasker", category: "sync")

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  // MARK: - Authentication & Fetch

  func login() async -> Bool {
    guard let coordinator else { return false }
    return await coordinator.repository.login()
  }

  func fetchTopTask() async {
    guard let coordinator else { return }
    if coordinator.canSyncRemotely && coordinator.listId.isEmpty { return }

    coordinator.errorMessage = nil

    do {
      try await coordinator.withLoadingState {
        let previousTasks = coordinator.tasks
        let fetchedTasks = try await coordinator.repository.activeSyncPlugin.fetchOpenTasks(
          listId: coordinator.listId,
          credentials: coordinator.activeCredentials
        )

        coordinator.tasks = fetchedTasks
        coordinator.repository.activeSyncPlugin.persistTaskCache(
          listId: coordinator.listId, tasks: fetchedTasks)
        coordinator.reconcilePriorityQueueWithOpenTasks()
        coordinator.reconcilePendingObsidianSyncQueueWithOpenTasks()
        if coordinator.rootTaskView == .kanban {
          coordinator.kanban.clampKanbanSelection()
        } else if coordinator.navigationState.currentSiblingIndex >= fetchedTasks.count {
          coordinator.navigationState.currentSiblingIndex = 0
        }
        coordinator.focusSessionManager.clampForTasks(fetchedTasks)
        let latestOpenTaskIDs = Set(fetchedTasks.map(\.id))
        let previousTimerNodes = previousTasks.map {
          TimerNode(id: $0.id, parentId: $0.parentId)
        }
        coordinator.timer.timerByTaskId = TimerElapsedReassignmentPolicy.remapElapsed(
          previousNodes: previousTimerNodes,
          latestOpenTaskIDs: latestOpenTaskIDs,
          elapsedByTaskID: coordinator.timer.timerByTaskId
        )
        coordinator.timer.stopTimerIfTaskRemoved(openTaskIds: latestOpenTaskIDs)
        if let filterParentId = coordinator.kanban.kanbanFilterParentId,
          !latestOpenTaskIDs.contains(filterParentId)
        {
          coordinator.kanban.kanbanFilterParentId = nil
          if coordinator.rootTaskView == .kanban {
            coordinator.navigationState.currentParentId = 0
          }
        }
        if !coordinator.listId.isEmpty && coordinator.canAttemptLogin {
          coordinator.onboardingCompleted = true
        }
      }
    } catch CheckvistSessionError.authenticationUnavailable {
      coordinator.setAuthenticationRequiredErrorIfNeeded()
    } catch {
      logger.error("Fetch tasks failed: \(error.localizedDescription, privacy: .public)")
      coordinator.errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
    }
  }

  // MARK: - List Management

  func fetchLists() async -> Bool {
    guard let coordinator else { return false }
    return await coordinator.repository.fetchLists()
  }

  func loadCheckvistLists(assignFirstIfMissing: Bool = false) async -> Bool {
    guard let coordinator else { return false }
    return await coordinator.repository.loadCheckvistLists(
      assignFirstIfMissing: assignFirstIfMissing)
  }

  func switchCheckvistList(to rawListId: String) async {
    guard let coordinator else { return }
    let trimmedListId = rawListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedListId != coordinator.listId else { return }

    coordinator.listId = trimmedListId
    coordinator.navigationState.currentParentId = 0
    coordinator.navigationState.currentSiblingIndex = 0
    coordinator.repository.clearPendingOfflineWork()
    coordinator.kanban.kanbanFilterParentId = nil
    coordinator.kanban.kanbanSelectedTaskId = nil
    coordinator.errorMessage = nil
    await fetchTopTask()
  }

  func createCheckvistListAndSwitch(name: String) async -> Bool {
    guard let coordinator else { return false }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      coordinator.errorMessage = "List name cannot be empty."
      return false
    }

    coordinator.beginLoading()
    defer { coordinator.endLoading() }

    do {
      guard
        let createdList = try await coordinator.repository.activeSyncPlugin.createList(
          name: trimmedName,
          credentials: coordinator.activeCredentials
        )
      else {
        coordinator.errorMessage = "Failed to create list."
        return false
      }

      _ = await fetchLists()
      selectList(createdList)
      coordinator.errorMessage = "Created and switched to list: \(createdList.name)"
      await fetchTopTask()
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      coordinator.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      coordinator.errorMessage = "Failed to create list: \(error.localizedDescription)"
      return false
    }
  }

  func mergeOpenTasksBetweenLists(sourceListId: String, destinationListId: String) async -> Bool {
    guard let coordinator else { return false }
    let source = sourceListId.trimmingCharacters(in: .whitespacesAndNewlines)
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !source.isEmpty, !destination.isEmpty else {
      coordinator.errorMessage = "Choose both source and destination lists."
      return false
    }
    guard source != destination else {
      coordinator.errorMessage = "Source and destination list must be different."
      return false
    }

    coordinator.beginLoading()
    defer { coordinator.endLoading() }

    do {
      let sourceTasks = try await coordinator.repository.activeSyncPlugin.fetchOpenTasks(
        listId: source,
        credentials: coordinator.activeCredentials
      )
      guard !sourceTasks.isEmpty else {
        coordinator.errorMessage = "Source list has no open tasks to merge."
        return false
      }

      let orderedTasks = sourceTasks.sorted { lhs, rhs in
        let lhsLevel = lhs.level ?? 0
        let rhsLevel = rhs.level ?? 0
        if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }

        let lhsParent = lhs.parentId ?? 0
        let rhsParent = rhs.parentId ?? 0
        if lhsParent != rhsParent { return lhsParent < rhsParent }

        return (lhs.position ?? Int.max) < (rhs.position ?? Int.max)
      }

      let migrationResult = try await copyTasks(orderedTasks, to: destination)

      if destination == coordinator.listId {
        await fetchTopTask()
      }

      coordinator.errorMessage =
        migrationResult.skippedCount > 0
        ? "Merged \(migrationResult.mergedCount) tasks (\(migrationResult.skippedCount) skipped)."
        : "Merged \(migrationResult.mergedCount) tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      coordinator.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      coordinator.errorMessage = "Failed to merge lists: \(error.localizedDescription)"
      return false
    }
  }

  func selectList(_ list: CheckvistList) {
    coordinator?.repository.selectList(list)
  }

  func uploadOfflineTasksToCheckvist(destinationListId: String) async -> Bool {
    guard let coordinator else { return false }
    let destination = destinationListId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else {
      coordinator.errorMessage = "Choose a Checkvist destination list."
      return false
    }

    let offlineTasks =
      (try? await coordinator.repository.offlineSyncPlugin.fetchOpenTasks(
        listId: "", credentials: coordinator.activeCredentials)) ?? []
    guard !offlineTasks.isEmpty else {
      coordinator.errorMessage = "No offline tasks are available to upload."
      return false
    }

    let loginSucceeded = await login()
    guard loginSucceeded else { return false }

    coordinator.beginLoading()
    defer { coordinator.endLoading() }

    do {
      let migrationResult = try await copyTasks(offlineTasks, to: destination)

      if destination == coordinator.listId {
        await fetchTopTask()
      }

      coordinator.errorMessage =
        migrationResult.skippedCount > 0
        ? "Uploaded \(migrationResult.mergedCount) offline tasks (\(migrationResult.skippedCount) skipped)."
        : "Uploaded \(migrationResult.mergedCount) offline tasks."
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      coordinator.setAuthenticationRequiredErrorIfNeeded()
      return false
    } catch {
      coordinator.errorMessage = "Failed to upload offline tasks: \(error.localizedDescription)"
      return false
    }
  }

  private func copyTasks(_ sourceTasks: [CheckvistTask], to destinationListId: String) async throws
    -> (mergedCount: Int, skippedCount: Int)
  {
    guard let coordinator else { return (0, 0) }
    return try await coordinator.repository.copyTasks(sourceTasks, to: destinationListId)
  }

  // MARK: - Offline Mutation Queue

  /// Replays offline-queued creates, deletes, actions, and updates against
  /// the active sync plugin. Creates run first to build a `tempId → realId`
  /// map; later queues resolve negative ids through it so a delete or close
  /// of an offline-created task hits the correct server task. Any individual
  /// failure re-queues that item and suppresses the final `fetchTopTask` so
  /// optimistic UI state survives until the next reconnect attempt.
  func flushPendingTaskMutations() async {
    guard let coordinator else { return }
    let repo = coordinator.repository
    guard repo.hasPendingOfflineWork else { return }

    let creates = repo.pendingTaskCreates
    let deletes = repo.pendingTaskDeletes
    let actions = repo.pendingTaskActions
    let mutations = repo.pendingTaskMutations
    repo.clearPendingOfflineWork()

    var tempIdToRealId: [Int: Int] = [:]
    var anyFailure = false

    func resolve(_ id: Int) -> Int? {
      id >= 0 ? id : tempIdToRealId[id]
    }

    for pending in creates {
      let resolvedParentId: Int?
      if let parentId = pending.parentId, parentId < 0 {
        guard let realParentId = tempIdToRealId[parentId] else {
          // Parent create failed earlier; can't create child without it.
          // Re-queue the child so a future flush can try again once the
          // parent eventually succeeds.
          repo.enqueuePendingCreate(pending)
          anyFailure = true
          continue
        }
        resolvedParentId = realParentId
      } else {
        resolvedParentId = pending.parentId
      }

      do {
        if let newTask = try await repo.activeSyncPlugin.createTask(
          listId: coordinator.listId,
          content: pending.content,
          parentId: resolvedParentId,
          position: pending.position,
          credentials: coordinator.activeCredentials
        ) {
          tempIdToRealId[pending.tempId] = newTask.id
          if let idx = coordinator.tasks.firstIndex(where: { $0.id == pending.tempId }) {
            coordinator.tasks[idx] = newTask
          }
        } else {
          repo.enqueuePendingCreate(pending)
          anyFailure = true
        }
      } catch {
        repo.enqueuePendingCreate(pending)
        anyFailure = true
        logger.error(
          "Offline create replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for tempOrRealId in deletes {
      guard let realId = resolve(tempOrRealId) else {
        // Underlying create never succeeded; the delete is moot.
        continue
      }
      do {
        _ = try await repo.activeSyncPlugin.deleteTask(
          listId: coordinator.listId,
          taskId: realId,
          credentials: coordinator.activeCredentials)
      } catch {
        repo.enqueuePendingDelete(realId)
        anyFailure = true
        logger.error(
          "Offline delete replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for pending in actions {
      guard let realId = resolve(pending.taskId) else { continue }
      do {
        _ = try await repo.activeSyncPlugin.performTaskAction(
          listId: coordinator.listId,
          taskId: realId,
          action: pending.action,
          credentials: coordinator.activeCredentials)
      } catch {
        repo.enqueuePendingAction(
          PendingTaskAction(taskId: realId, action: pending.action))
        anyFailure = true
        logger.error(
          "Offline action replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    for (tempOrRealId, mutation) in mutations {
      guard let realId = resolve(tempOrRealId) else { continue }
      do {
        _ = try await repo.activeSyncPlugin.updateTask(
          listId: coordinator.listId,
          taskId: realId,
          content: mutation.content,
          due: mutation.due,
          credentials: coordinator.activeCredentials)
      } catch {
        repo.enqueuePendingMutation(
          taskId: realId, content: mutation.content, due: mutation.due)
        anyFailure = true
        logger.error(
          "Offline update replay failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    if !anyFailure {
      await fetchTopTask()
    }
  }

  // MARK: - Reorder

  func moveTask(_ task: CheckvistTask, direction: Int) async {
    guard let coordinator else { return }
    guard direction == -1 || direction == 1 else { return }

    switch coordinator.rootTaskView {
    case .priority:
      movePriorityTask(task, direction: direction)
    case .kanban:
      moveTaskWithinKanbanColumn(task: task, direction: direction)
    case .due:
      moveDueTaskByCopyingDate(task: task, direction: direction)
    case .all, .tags, .eisenhower:
      swapWithSiblingNeighbour(task: task, direction: direction)
    }
  }

  /// Position-based sibling swap. Moves the task one slot up/down within its
  /// parent's sibling list. Visible immediately in views sorted by position
  /// (All, Tags, sub-level scopes).
  private func swapWithSiblingNeighbour(task: CheckvistTask, direction: Int) {
    guard let coordinator else { return }
    let siblings =
      coordinator.tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard siblings.indices.contains(newIdx) else { return }
    let neighbour = siblings[newIdx]
    performSiblingPositionSwap(
      task: task, neighbour: neighbour, direction: direction, targetPosition: newIdx + 1
    )
  }

  /// Within kanban, reorder against the visible neighbour in the column that
  /// hosts the moving task. Purely visual: writes only to the per-column
  /// manual-order overlay, never to a task's date, priority, or position.
  private func moveTaskWithinKanbanColumn(task: CheckvistTask, direction: Int) {
    guard let coordinator else { return }
    let columns = coordinator.kanban.kanbanColumns
    var hostingColumn: KanbanColumn?
    for column in columns {
      let colTasks = coordinator.kanban.tasksForKanbanColumn(column, allColumns: columns)
      if colTasks.contains(where: { $0.id == task.id }) {
        hostingColumn = column
        break
      }
    }
    guard let column = hostingColumn else { return }
    coordinator.kanban.nudgeTaskInColumn(taskId: task.id, in: column, direction: direction)
  }

  /// In the Due view, Cmd+Up/Down copies the visible neighbour's due date so
  /// the task slides into a new bucket. After copy, also nudges position so
  /// the task lands above (Cmd+Up) or below (Cmd+Down) the neighbour —
  /// otherwise they share a bucket+date and the position-tiebreak could
  /// place the task on the wrong side of the neighbour.
  private func moveDueTaskByCopyingDate(task: CheckvistTask, direction: Int) {
    guard let coordinator else { return }
    let visible = coordinator.visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let neighbourDue = neighbour.due ?? ""
    let taskDue = task.due ?? ""

    if neighbourDue != taskDue {
      let neighbourPos = neighbour.position ?? 1
      let newPosition = direction < 0 ? max(1, neighbourPos - 1) : neighbourPos + 1
      if let idx = coordinator.tasks.firstIndex(where: { $0.id == task.id }) {
        coordinator.tasks[idx] = taskWithPosition(coordinator.tasks[idx], position: newPosition)
      }
      coordinator.applyOptimisticMoveAndSync(task: task, content: nil, due: neighbourDue)
      enqueueReorderRequest(taskId: task.id, position: newPosition)
    } else if (task.parentId ?? 0) == (neighbour.parentId ?? 0) {
      swapWithSiblingNeighbour(task: task, direction: direction)
    }
  }

  /// Optimistic position swap of `task` and `neighbour` (same parent). Updates
  /// `tasks` in place and enqueues the server-side reorder.
  private func performSiblingPositionSwap(
    task: CheckvistTask, neighbour: CheckvistTask, direction: Int, targetPosition: Int
  ) {
    guard let coordinator else { return }

    // Compute deterministic positions for both tasks. Don't rely on the
    // moving task's original position — if it was nil/sparse, copying it to
    // the neighbour would leave the comparator falling back to alphabetical
    // sort, which often matches the previous order and looks like no move
    // happened at all.
    let neighbourTargetPosition = max(1, targetPosition - direction)

    if let movingRange = coordinator.subtreeBlockRange(for: task.id, in: coordinator.tasks),
      let neighbourRange =
        coordinator.subtreeBlockRange(for: neighbour.id, in: coordinator.tasks)
    {
      var updated = coordinator.tasks
      let movingBlock = Array(updated[movingRange])
      updated.removeSubrange(movingRange)

      let insertIndex: Int
      if direction > 0 {
        // Neighbour was below; after removing our block, its end index shifts
        // left.
        insertIndex = neighbourRange.upperBound - movingBlock.count
      } else {
        // Neighbour was above; its range is unaffected by the removal.
        insertIndex = neighbourRange.lowerBound
      }
      updated.insert(contentsOf: movingBlock, at: max(0, min(updated.count, insertIndex)))

      if let movedIdx = updated.firstIndex(where: { $0.id == task.id }) {
        updated[movedIdx] = taskWithPosition(updated[movedIdx], position: targetPosition)
      }
      if let neighbourIdx = updated.firstIndex(where: { $0.id == neighbour.id }) {
        updated[neighbourIdx] = taskWithPosition(
          updated[neighbourIdx], position: neighbourTargetPosition)
      }

      coordinator.tasks = updated
      // Keep selection anchored to the moved task in the currently visible
      // list.
      if let visibleIdx = coordinator.visibleTasks.firstIndex(where: { $0.id == task.id }) {
        coordinator.navigationState.currentSiblingIndex = visibleIdx
      }
    }

    enqueueReorderRequest(taskId: task.id, position: targetPosition)
  }

  /// Reorder within the priority view by swapping the visible neighbour's
  /// slot only when both tasks compete in the same priority queue (both
  /// absolute, or both scoped under the same parent). Unrelated tasks —
  /// different parent scopes, or one absolute and one scoped — don't have
  /// comparable rankings, so we leave them alone instead of stealing each
  /// other's slot.
  func movePriorityTask(_ task: CheckvistTask, direction: Int) {
    guard let coordinator else { return }
    let visible = coordinator.visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let absoluteQueue = coordinator.repository.absolutePriorityTaskIds
    let byParent = coordinator.repository.priorityTaskIdsByParentId

    let taskAbs = absoluteQueue.firstIndex(of: task.id)
    let neighbourAbs = absoluteQueue.firstIndex(of: neighbour.id)

    if let i1 = taskAbs, let i2 = neighbourAbs {
      var queue = absoluteQueue
      queue.swapAt(i1, i2)
      coordinator.repository.saveAbsolutePriorityQueue(queue)
      coordinator.navigationState.currentSiblingIndex = newIdx
      return
    }

    let taskScope = priorityScope(for: task.id, in: byParent)
    let neighbourScope = priorityScope(for: neighbour.id, in: byParent)

    if let (p1, i1) = taskScope, let (p2, i2) = neighbourScope, p1 == p2 {
      var updated = byParent
      var queue = updated[p1] ?? []
      queue.swapAt(i1, i2)
      updated[p1] = queue
      coordinator.savePriorityQueue(updated)
      coordinator.navigationState.currentSiblingIndex = newIdx
    }
  }

  private func priorityScope(
    for taskId: Int, in byParent: [Int: [Int]]
  ) -> (parentId: Int, index: Int)? {
    for (parentId, ids) in byParent {
      if let idx = ids.firstIndex(of: taskId) { return (parentId, idx) }
    }
    return nil
  }

  private func taskWithPosition(_ task: CheckvistTask, position: Int?) -> CheckvistTask {
    CheckvistTask(
      id: task.id,
      content: task.content,
      status: task.status,
      due: task.due,
      position: position,
      parentId: task.parentId,
      level: task.level
    )
  }

  // MARK: - Reorder Queue

  private func enqueueReorderRequest(taskId: Int, position: Int) {
    guard let coordinator else { return }
    coordinator.repository.reorderQueue.enqueue(taskId: taskId, position: position)
    startReorderSyncIfNeeded()
  }

  private func startReorderSyncIfNeeded() {
    guard let coordinator else { return }
    guard !coordinator.repository.reorderQueue.isSyncing else { return }

    let task = Task { [weak self, weak coordinator] in
      guard let self else { return }
      var hadFailure = false

      while true {
        let nextRequest: ReorderQueue.Request? = await MainActor.run {
          coordinator?.repository.reorderQueue.dequeueNext()
        }

        guard let nextRequest else { break }
        let success = await self.commitReorderRequest(
          taskId: nextRequest.taskId, position: nextRequest.position)
        if !success { hadFailure = true }
      }

      await MainActor.run {
        coordinator?.repository.reorderQueue.setSyncTask(nil)
        if hadFailure { self.scheduleReorderResync() }
        if let coordinator,
          !coordinator.repository.reorderQueue.pending.isEmpty
        {
          self.startReorderSyncIfNeeded()
        }
      }
    }
    coordinator.repository.reorderQueue.setSyncTask(task)
  }

  private func commitReorderRequest(taskId: Int, position: Int) async -> Bool {
    guard let coordinator else { return false }
    do {
      let success = try await coordinator.repository.activeSyncPlugin.moveTask(
        listId: coordinator.listId,
        taskId: taskId,
        position: position,
        credentials: coordinator.activeCredentials
      )
      if !success {
        await MainActor.run { [weak coordinator] in
          coordinator?.errorMessage = "Failed to move task."
        }
        return false
      }
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      return false
    } catch {
      await MainActor.run { [weak coordinator] in
        coordinator?.errorMessage = "Error: \(error.localizedDescription)"
      }
      return false
    }
  }

  private func scheduleReorderResync() {
    guard let coordinator else { return }
    let task = Task { [weak self, weak coordinator] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard let self else { return }
      await self.fetchTopTask()
      await MainActor.run {
        coordinator?.repository.reorderQueue.setResyncTask(nil)
      }
    }
    coordinator.repository.reorderQueue.setResyncTask(task)
  }

  // MARK: - Indent / Unindent

  func indentTask(_ task: CheckvistTask) async {
    guard let coordinator else { return }
    let siblings =
      coordinator.tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
    let newParent = siblings[idx - 1]

    await coordinator.runBooleanMutation(
      failureMessage: "Failed to indent task.",
      errorMessageBuilder: { "Error indenting task: \($0.localizedDescription)" },
      action: {
        try await coordinator.repository.activeSyncPlugin.reparentTask(
          listId: coordinator.listId,
          taskId: task.id,
          parentId: newParent.id,
          credentials: coordinator.activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }

  func unindentTask(_ task: CheckvistTask) async {
    guard let coordinator else { return }
    guard let parentId = task.parentId, parentId != 0 else { return }
    guard let parent = coordinator.tasks.first(where: { $0.id == parentId }) else { return }
    let newParentId = parent.parentId ?? 0

    await coordinator.runBooleanMutation(
      failureMessage: "Failed to unindent task.",
      errorMessageBuilder: { "Error unindenting task: \($0.localizedDescription)" },
      action: {
        try await coordinator.repository.activeSyncPlugin.reparentTask(
          listId: coordinator.listId,
          taskId: task.id,
          parentId: newParentId == 0 ? nil : newParentId,
          credentials: coordinator.activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }
}
