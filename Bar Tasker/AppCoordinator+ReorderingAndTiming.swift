import Foundation
import OSLog

extension AppCoordinator {
  // MARK: - Reorder

  @MainActor func moveTask(_ task: CheckvistTask, direction: Int) async {
    guard direction == -1 || direction == 1 else { return }

    switch rootTaskView {
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
  @MainActor private func swapWithSiblingNeighbour(task: CheckvistTask, direction: Int) {
    let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
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
  @MainActor private func moveTaskWithinKanbanColumn(task: CheckvistTask, direction: Int) {
    let columns = kanban.kanbanColumns
    var hostingColumn: KanbanColumn?
    for column in columns {
      let colTasks = kanban.tasksForKanbanColumn(column, allColumns: columns)
      if colTasks.contains(where: { $0.id == task.id }) {
        hostingColumn = column
        break
      }
    }
    guard let column = hostingColumn else { return }
    kanban.nudgeTaskInColumn(taskId: task.id, in: column, direction: direction)
  }

  /// In the Due view, Cmd+Up/Down copies the visible neighbour's due date so
  /// the task slides into a new bucket. After copy, also nudges position so the
  /// task lands above (Cmd+Up) or below (Cmd+Down) the neighbour — otherwise
  /// they share a bucket+date and the position-tiebreak could place the task
  /// on the wrong side of the neighbour.
  @MainActor private func moveDueTaskByCopyingDate(task: CheckvistTask, direction: Int) {
    let visible = visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let neighbourDue = neighbour.due ?? ""
    let taskDue = task.due ?? ""

    if neighbourDue != taskDue {
      let neighbourPos = neighbour.position ?? 1
      let newPosition = direction < 0 ? max(1, neighbourPos - 1) : neighbourPos + 1
      if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
        tasks[idx] = taskWithPosition(tasks[idx], position: newPosition)
      }
      applyOptimisticMoveAndSync(task: task, content: nil, due: neighbourDue)
      enqueueReorderRequest(taskId: task.id, position: newPosition)
    } else if (task.parentId ?? 0) == (neighbour.parentId ?? 0) {
      swapWithSiblingNeighbour(task: task, direction: direction)
    }
  }

  /// Optimistic position swap of `task` and `neighbour` (same parent). Updates
  /// `tasks` in place and enqueues the server-side reorder.
  @MainActor private func performSiblingPositionSwap(
    task: CheckvistTask, neighbour: CheckvistTask, direction: Int, targetPosition: Int
  ) {
    // Compute deterministic positions for both tasks. Don't rely on the
    // moving task's original position — if it was nil/sparse, copying it to
    // the neighbour would leave the comparator falling back to alphabetical
    // sort, which often matches the previous order and looks like no move
    // happened at all.
    let neighbourTargetPosition = max(1, targetPosition - direction)

    if let movingRange = subtreeBlockRange(for: task.id, in: tasks),
      let neighbourRange = subtreeBlockRange(for: neighbour.id, in: tasks)
    {
      var updated = tasks
      let movingBlock = Array(updated[movingRange])
      updated.removeSubrange(movingRange)

      let insertIndex: Int
      if direction > 0 {
        // Neighbour was below; after removing our block, its end index shifts left.
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

      tasks = updated
      // Keep selection anchored to the moved task in the currently visible list.
      if let visibleIdx = visibleTasks.firstIndex(where: { $0.id == task.id }) {
        currentSiblingIndex = visibleIdx
      }
    }

    enqueueReorderRequest(taskId: task.id, position: targetPosition)
  }

  /// Reorder within the priority view by swapping the visible neighbour's slot
  /// only when both tasks compete in the same priority queue (both absolute, or
  /// both scoped under the same parent). Unrelated tasks — different parent
  /// scopes, or one absolute and one scoped — don't have comparable rankings,
  /// so we leave them alone instead of stealing each other's slot.
  @MainActor func movePriorityTask(_ task: CheckvistTask, direction: Int) {
    let visible = visibleTasks
    guard let idx = visible.firstIndex(where: { $0.id == task.id }) else { return }
    let newIdx = idx + direction
    guard visible.indices.contains(newIdx) else { return }
    let neighbour = visible[newIdx]

    let absoluteQueue = repository.absolutePriorityTaskIds
    let byParent = repository.priorityTaskIdsByParentId

    let taskAbs = absoluteQueue.firstIndex(of: task.id)
    let neighbourAbs = absoluteQueue.firstIndex(of: neighbour.id)

    if let i1 = taskAbs, let i2 = neighbourAbs {
      var queue = absoluteQueue
      queue.swapAt(i1, i2)
      repository.saveAbsolutePriorityQueue(queue)
      currentSiblingIndex = newIdx
      return
    }

    let taskScope = priorityScope(for: task.id, in: byParent)
    let neighbourScope = priorityScope(for: neighbour.id, in: byParent)

    if let (p1, i1) = taskScope, let (p2, i2) = neighbourScope, p1 == p2 {
      var updated = byParent
      var queue = updated[p1] ?? []
      queue.swapAt(i1, i2)
      updated[p1] = queue
      savePriorityQueue(updated)
      currentSiblingIndex = newIdx
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

  @MainActor private func enqueueReorderRequest(taskId: Int, position: Int) {
    repository.reorderQueue.enqueue(taskId: taskId, position: position)
    startReorderSyncIfNeeded()
  }

  @MainActor private func startReorderSyncIfNeeded() {
    guard !repository.reorderQueue.isSyncing else { return }

    let task = Task { [weak self] in
      guard let self else { return }
      var hadFailure = false

      while true {
        let nextRequest: ReorderQueue.Request? = await MainActor.run {
          self.repository.reorderQueue.dequeueNext()
        }

        guard let nextRequest else { break }
        let success = await self.commitReorderRequest(
          taskId: nextRequest.taskId, position: nextRequest.position)
        if !success { hadFailure = true }
      }

      await MainActor.run {
        self.repository.reorderQueue.setSyncTask(nil)
        if hadFailure { self.scheduleReorderResync() }
        if !self.repository.reorderQueue.pending.isEmpty {
          self.startReorderSyncIfNeeded()
        }
      }
    }
    repository.reorderQueue.setSyncTask(task)
  }

  private func commitReorderRequest(taskId: Int, position: Int) async -> Bool {
    do {
      let success = try await repository.activeSyncPlugin.moveTask(
        listId: listId,
        taskId: taskId,
        position: position,
        credentials: activeCredentials
      )
      if !success {
        await MainActor.run {
          self.errorMessage = "Failed to move task."
        }
        return false
      }
      return true
    } catch CheckvistSessionError.authenticationUnavailable {
      return false
    } catch {
      await MainActor.run {
        self.errorMessage = "Error: \(error.localizedDescription)"
      }
      return false
    }
  }

  // Timer methods are now on TimerManager (accessed via `timer.*`)

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

  func totalElapsed(forTaskId taskId: Int) -> TimeInterval {
    rolledUpElapsedByTaskId()[taskId] ?? 0
  }

  func totalElapsed(for task: CheckvistTask) -> TimeInterval {
    totalElapsed(forTaskId: task.id)
  }

  func childCountByTaskId() -> [Int: Int] {
    ensureVisibleTasksCacheValid()
    return cache.childCount
  }

  func rolledUpElapsedByTaskId() -> [Int: TimeInterval] {
    // Touch the observable dictionary so SwiftUI re-renders on per-second ticks.
    // Without this, callers only read the @ObservationIgnored cache and never
    // establish a dependency on `timer.timerByTaskId`.
    _ = timer.timerByTaskId
    ensureVisibleTasksCacheValid()
    return cache.rolledUpElapsed
  }

  @MainActor private func scheduleReorderResync() {
    let task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard let self else { return }
      await self.fetchTopTask()
      await MainActor.run {
        self.repository.reorderQueue.setResyncTask(nil)
      }
    }
    repository.reorderQueue.setResyncTask(task)
  }

  // MARK: - Indent / Unindent

  @MainActor func indentTask(_ task: CheckvistTask) async {
    let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
    guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
    let newParent = siblings[idx - 1]

    await runBooleanMutation(
      failureMessage: "Failed to indent task.",
      errorMessageBuilder: { "Error indenting task: \($0.localizedDescription)" },
      action: {
        try await repository.activeSyncPlugin.reparentTask(
          listId: listId,
          taskId: task.id,
          parentId: newParent.id,
          credentials: activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }

  @MainActor func unindentTask(_ task: CheckvistTask) async {
    guard let parentId = task.parentId, parentId != 0 else { return }
    guard let parent = tasks.first(where: { $0.id == parentId }) else { return }
    let newParentId = parent.parentId ?? 0

    await runBooleanMutation(
      failureMessage: "Failed to unindent task.",
      errorMessageBuilder: { "Error unindenting task: \($0.localizedDescription)" },
      action: {
        try await repository.activeSyncPlugin.reparentTask(
          listId: listId,
          taskId: task.id,
          parentId: newParentId == 0 ? nil : newParentId,
          credentials: activeCredentials
        )
      },
      onSuccess: { [weak self] in
        await self?.fetchTopTask()
      }
    )
  }
}
